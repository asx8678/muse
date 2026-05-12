defmodule Muse.Weft.Proxy.Download do
  @moduledoc """
  Download and optionally extract archives for Weft channels.

  ## Endpoint

      GET /download?key=<key>&url=<url>&extract=<path>&token=<token>

  ## Parameters

  - `key` — unique cache key for concurrent download sharing
  - `url` — URL to download (http or https only)
  - `extract` — (optional) target directory to extract into
  - `token` — auth token

  ## Opt-in

  The download service is active only when enabled in config:

      config :muse, :weft, enabled_channels: ["download"]
  """

  @behaviour Plug

  import Plug.Conn

  alias MuseWeb.ExternalSocketAuth

  @table :weft_download_cache
  @max_size 100 * 1024 * 1024
  @default_timeout 30_000

  @impl Plug
  def init(opts) do
    opts
    |> Keyword.put_new(:timeout, @default_timeout)
    |> Keyword.put_new(:max_size, @max_size)
    |> Keyword.put_new(:download_fn, &default_download/3)
    |> Keyword.put_new(:extract_fn, &default_extract/3)
    |> Keyword.put_new(:allowed_extract_base, System.tmp_dir!())
  end

  @impl Plug
  def call(conn, opts) do
    if not download_enabled?() do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{"error" => "download_disabled"}))
      |> halt()
    else
      conn = fetch_query_params(conn)

      with {:ok, conn} <- validate_params(conn, opts),
           {:ok, conn} <- authenticate(conn) do
        handle_download(conn, opts)
      else
        {:error, :missing_url} ->
          send_json_resp(conn, 400, %{"error" => "missing_url"}) |> halt()

        {:error, :missing_key} ->
          send_json_resp(conn, 400, %{"error" => "missing_key"}) |> halt()

        {:error, :invalid_url} ->
          send_json_resp(conn, 400, %{"error" => "invalid_url"}) |> halt()

        {:error, :invalid_key} ->
          send_json_resp(conn, 400, %{"error" => "invalid_key"}) |> halt()

        {:error, :unauthorized} ->
          send_json_resp(conn, 401, %{"error" => "unauthorized"}) |> halt()

        {:error, :invalid_extract_path} ->
          send_json_resp(conn, 400, %{"error" => "invalid_extract_path"}) |> halt()

        {:error, :path_traversal} ->
          send_json_resp(conn, 400, %{"error" => "path_traversal"}) |> halt()

        {:error, :extract_outside_base} ->
          send_json_resp(conn, 403, %{"error" => "extract_outside_base"}) |> halt()
      end
    end
  end

  # -- Config ------------------------------------------------------------------

  defp download_enabled? do
    Application.get_env(:muse, :weft, [])
    |> Keyword.get(:enabled_channels, [])
    |> Enum.member?("download")
  end

  # -- Validation --------------------------------------------------------------

  defp validate_params(conn, opts) do
    with :ok <- require_url(conn),
         :ok <- require_key(conn),
         :ok <- validate_extract(conn, opts) do
      {:ok, conn}
    end
  end

  defp require_url(conn) do
    url = conn.query_params["url"]

    if is_nil(url) or url == "" do
      {:error, :missing_url}
    else
      case validate_url(url) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, url}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp require_key(conn) do
    key = conn.query_params["key"]

    cond do
      is_nil(key) or key == "" ->
        {:error, :missing_key}

      not String.printable?(key) ->
        {:error, :invalid_key}

      true ->
        :ok
    end
  end

  defp validate_extract(conn, opts) do
    case conn.query_params["extract"] do
      nil -> :ok
      "" -> :ok
      path -> do_validate_extract(path, opts)
    end
  end

  defp do_validate_extract(path, opts) do
    if Path.type(path) != :absolute do
      {:error, :invalid_extract_path}
    else
      if String.contains?(path, "..") do
        {:error, :path_traversal}
      else
        base = Keyword.get(opts, :allowed_extract_base, System.tmp_dir!())
        expanded = Path.expand(path)
        base_expanded = Path.expand(base)

        if String.starts_with?(expanded, base_expanded) do
          :ok
        else
          {:error, :extract_outside_base}
        end
      end
    end
  end

  # -- Authentication ----------------------------------------------------------

  defp authenticate(conn) do
    token = conn.query_params["token"]

    case ExternalSocketAuth.authenticate(%{"token" => token}) do
      {:ok, _principal} -> {:ok, conn}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  # -- Download handling -------------------------------------------------------

  defp handle_download(conn, opts) do
    key = conn.query_params["key"]
    url = conn.query_params["url"]
    extract = conn.query_params["extract"]

    ensure_cache_table()

    case acquire_or_wait(key, url, opts) do
      {:primary, result} ->
        stream_primary_response(conn, result, extract, opts)

      {:waiter, result} ->
        send_waiter_response(conn, result, extract, opts)
    end
  end

  defp ensure_cache_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp acquire_or_wait(key, url, opts) do
    case :ets.insert_new(@table, {key, {:downloading, self()}}) do
      true ->
        result = run_download(url, opts)
        :ets.insert(@table, {key, {:done, result}})
        {:primary, result}

      false ->
        case :ets.lookup(@table, key) do
          [{^key, {:downloading, pid}}] ->
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, ^pid, _reason} ->
                case :ets.lookup(@table, key) do
                  [{^key, {:done, result}}] -> {:waiter, result}
                  _ -> {:waiter, {:error, :download_failed}}
                end
            after
              opts[:timeout] + 5_000 -> {:waiter, {:error, :timeout}}
            end

          [{^key, {:done, result}}] ->
            {:waiter, result}
        end
    end
  end

  defp run_download(url, opts) do
    temp_path = temp_file_path()
    _cleanup_pid = spawn_cleanup_monitor(self(), temp_path)

    download_fn = Keyword.get(opts, :download_fn, &default_download/3)

    try do
      download_fn.(url, Keyword.get(opts, :max_size, @max_size), temp_path)
    rescue
      e -> {:error, :download_failed, Exception.message(e)}
    catch
      kind, reason -> {:error, :download_failed, "#{kind}: #{inspect(reason)}"}
    end
  end

  defp spawn_cleanup_monitor(parent_pid, temp_path) do
    spawn(fn ->
      Process.flag(:trap_exit, true)
      ref = Process.monitor(parent_pid)

      receive do
        {:DOWN, ^ref, :process, ^parent_pid, _reason} ->
          File.rm(temp_path)
      end
    end)
  end

  defp temp_file_path do
    tmp = System.tmp_dir!()
    Path.join(tmp, "weft-download-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp default_download(url, max_size, temp_path) do
    try do
      case Req.get(url: url, max_redirects: 5, into: temp_path) do
        {:ok, %Req.Response{status: status}} when status >= 200 and status < 300 ->
          size = File.stat!(temp_path).size

          if size > max_size do
            File.rm(temp_path)
            {:error, :too_large}
          else
            {:ok, temp_path, size}
          end

        {:ok, %Req.Response{status: status}} ->
          File.rm(temp_path)
          {:error, {:http_error, status}}

        {:error, %Req.TransportError{reason: reason}} ->
          File.rm(temp_path)
          {:error, {:transport_error, reason}}

        {:error, reason} ->
          File.rm(temp_path)
          {:error, reason}
      end
    rescue
      e ->
        File.rm(temp_path)
        {:error, Exception.message(e)}
    end
  end

  # -- Response streaming ------------------------------------------------------

  defp stream_primary_response(conn, result, extract, opts) do
    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> send_chunked(200)

    {conn, final_body} =
      case result do
        {:ok, temp_path, size} ->
          {:ok, conn} =
            chunk(conn, ndjson(%{"type" => "progress", "downloaded" => size, "total" => size}))

          case maybe_extract_and_respond(temp_path, extract, opts) do
            {:ok, extracted_paths} ->
              {conn,
               %{
                 "type" => "complete",
                 "path" => temp_path,
                 "extracted" => extracted_paths
               }}

            {:error, reason} ->
              {conn, %{"type" => "error", "message" => extract_error_message(reason)}}
          end

        {:error, :too_large} ->
          {conn, %{"type" => "error", "message" => "download exceeds 100MB"}}

        {:error, reason} ->
          {conn, %{"type" => "error", "message" => download_error_message(reason)}}

        {:error, :download_failed, msg} ->
          {conn, %{"type" => "error", "message" => msg}}
      end

    {:ok, conn} = chunk(conn, ndjson(final_body))
    conn |> halt()
  end

  defp send_waiter_response(conn, result, extract, opts) do
    case result do
      {:ok, temp_path, _size} ->
        case maybe_extract_and_respond(temp_path, extract, opts) do
          {:ok, extracted_paths} ->
            send_json_resp(conn, 200, %{
              "status" => "complete",
              "path" => temp_path,
              "extracted" => extracted_paths
            })

          {:error, reason} ->
            send_json_resp(conn, 502, %{
              "error" => "extraction_failed",
              "detail" => extract_error_message(reason)
            })
        end

      {:error, :too_large} ->
        send_json_resp(conn, 413, %{"error" => "download_too_large"})

      {:error, reason} ->
        send_json_resp(conn, 502, %{
          "error" => "download_failed",
          "detail" => download_error_message(reason)
        })

      {:error, :download_failed, msg} ->
        send_json_resp(conn, 502, %{
          "error" => "download_failed",
          "detail" => msg
        })
    end
    |> halt()
  end

  defp maybe_extract_and_respond(_temp_path, nil, _opts), do: {:ok, []}
  defp maybe_extract_and_respond(_temp_path, "", _opts), do: {:ok, []}

  defp maybe_extract_and_respond(temp_path, extract_path, opts) do
    extract_fn = Keyword.get(opts, :extract_fn, &default_extract/3)
    extract_fn.(temp_path, extract_path, opts)
  end

  defp default_extract(archive_path, extract_path, _opts) do
    cond do
      String.ends_with?(archive_path, [".tar.gz", ".tgz"]) ->
        extract_tar(archive_path, extract_path)

      String.ends_with?(archive_path, ".zip") ->
        extract_zip(archive_path, extract_path)

      true ->
        case File.read(archive_path) do
          {:ok, <<0x1F, 0x8B, _rest::binary>>} -> extract_tar(archive_path, extract_path)
          {:ok, <<0x50, 0x4B, _rest::binary>>} -> extract_zip(archive_path, extract_path)
          _ -> {:error, :unknown_archive_format}
        end
    end
  end

  defp extract_tar(archive_path, extract_path) do
    tar_charlist = String.to_charlist(archive_path)

    case :erl_tar.table(tar_charlist, [:compressed]) do
      {:ok, entries} ->
        if path_traversal_in_entries?(entries) do
          {:error, :path_traversal_in_archive}
        else
          File.mkdir_p!(extract_path)

          case :erl_tar.extract(tar_charlist, [
                 :compressed,
                 :keep_mode,
                 cwd: String.to_charlist(extract_path)
               ]) do
            :ok ->
              paths = list_extracted_paths(extract_path)
              {:ok, paths}

            {:error, reason} ->
              {:error, {:tar_extract_failed, reason}}
          end
        end

      {:error, reason} ->
        {:error, {:tar_list_failed, reason}}
    end
  end

  defp extract_zip(archive_path, extract_path) do
    case System.cmd("unzip", ["-l", archive_path], stderr_to_stdout: true) do
      {output, 0} ->
        entries = parse_unzip_list(output)

        if path_traversal_in_entries?(entries) do
          {:error, :path_traversal_in_archive}
        else
          File.mkdir_p!(extract_path)

          case System.cmd("unzip", ["-o", archive_path, "-d", extract_path],
                 stderr_to_stdout: true
               ) do
            {_output, 0} ->
              paths = list_extracted_paths(extract_path)
              {:ok, paths}

            {output, code} ->
              {:error, {:unzip_failed, code, output}}
          end
        end

      {output, code} ->
        {:error, {:unzip_list_failed, code, output}}
    end
  end

  defp parse_unzip_list(output) do
    output
    |> String.split("\n")
    |> Enum.drop(3)
    |> Enum.reverse()
    |> Enum.drop(2)
    |> Enum.reverse()
    |> Enum.map(fn line ->
      line
      |> String.split(" ", trim: true)
      |> List.last()
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp path_traversal_in_entries?(entries) do
    entries
    |> Enum.map(&to_string/1)
    |> Enum.any?(fn entry ->
      String.contains?(entry, "..") or Path.type(entry) == :absolute
    end)
  end

  defp list_extracted_paths(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
  end

  # -- Helpers -----------------------------------------------------------------

  defp send_json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp ndjson(map) do
    Jason.encode!(map) <> "\n"
  end

  defp download_error_message({:http_error, status}), do: "HTTP error #{status}"

  defp download_error_message({:transport_error, reason}) do
    "transport error: #{inspect(reason)}"
  end

  defp download_error_message(reason) when is_binary(reason), do: reason
  defp download_error_message(reason), do: inspect(reason)

  defp extract_error_message(:path_traversal_in_archive),
    do: "path traversal detected in archive"

  defp extract_error_message(:unknown_archive_format), do: "unknown archive format"

  defp extract_error_message({:tar_extract_failed, reason}),
    do: "tar extraction failed: #{inspect(reason)}"

  defp extract_error_message({:tar_list_failed, reason}),
    do: "tar listing failed: #{inspect(reason)}"

  defp extract_error_message({:unzip_failed, code, _output}),
    do: "unzip failed with code #{code}"

  defp extract_error_message({:unzip_list_failed, code, _output}),
    do: "unzip listing failed with code #{code}"

  defp extract_error_message(reason), do: inspect(reason)
end
