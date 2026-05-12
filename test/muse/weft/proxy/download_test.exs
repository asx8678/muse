defmodule Muse.Weft.Proxy.DownloadTest do
  @moduledoc """
  Tests for the Weft download proxy plug.

  All network calls are injected via `download_fn`.  Real archive fixtures
  are used for extraction tests.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Muse.Weft.Proxy.Download

  @fixture_dir Path.join([__DIR__, "../../../fixtures/download"])
  @tar_fixture Path.join(@fixture_dir, "small.tar.gz")
  @zip_fixture Path.join(@fixture_dir, "small.zip")

  setup do
    original_weft = Application.get_env(:muse, :weft)
    Application.put_env(:muse, :weft, enabled_channels: ["download"])

    # Clean the shared ETS cache before each test.
    case :ets.whereis(:weft_download_cache) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(:weft_download_cache)
    end

    on_exit(fn ->
      if original_weft do
        Application.put_env(:muse, :weft, original_weft)
      else
        Application.delete_env(:muse, :weft)
      end

      case :ets.whereis(:weft_download_cache) do
        :undefined -> :ok
        _tid -> :ets.delete_all_objects(:weft_download_cache)
      end
    end)

    :ok
  end

  describe "GET /download validation" do
    test "missing url returns 400" do
      conn =
        conn(:get, "/download?key=k1&token=test-token-16chars-ok")
        |> Download.call(Download.init([]))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "missing_url"}
    end

    test "missing key returns 400" do
      conn =
        conn(:get, "/download?url=http://example.com/file.txt&token=test-token-16chars-ok")
        |> Download.call(Download.init([]))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "missing_key"}
    end

    test "invalid URL scheme returns 400" do
      conn =
        conn(:get, "/download?key=k1&url=file:///etc/passwd&token=test-token-16chars-ok")
        |> Download.call(Download.init([]))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_url"}
    end

    test "URL without host returns 400" do
      conn =
        conn(:get, "/download?key=k1&url=http://&token=test-token-16chars-ok")
        |> Download.call(Download.init([]))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_url"}
    end

    test "missing auth token returns 401" do
      conn =
        conn(:get, "/download?key=k1&url=http://example.com/file.txt")
        |> Download.call(Download.init([]))

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    end
  end

  describe "GET /download disabled" do
    test "returns 503 when download channel is not enabled" do
      Application.put_env(:muse, :weft, enabled_channels: [])

      conn =
        conn(:get, "/download?key=k1&url=http://example.com/file.txt&token=test-token-16chars-ok")
        |> Download.call(Download.init([]))

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"error" => "download_disabled"}
    end
  end

  describe "GET /download extraction path validation" do
    test "relative extract path returns 400" do
      conn =
        conn(
          :get,
          "/download?key=k1&url=http://example.com/f.tgz&extract=relative/dir&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init([]))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_extract_path"}
    end

    test "extract path with .. returns 400" do
      conn =
        conn(
          :get,
          "/download?key=k1&url=http://example.com/f.tgz&extract=/tmp/../etc&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init([]))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "path_traversal"}
    end

    test "extract path outside allowed base returns 403" do
      conn =
        conn(
          :get,
          "/download?key=k1&url=http://example.com/f.tgz&extract=/etc&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init(allowed_extract_base: "/tmp/safe"))

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => "extract_outside_base"}
    end
  end

  describe "GET /download happy path" do
    test "successful download streams NDJSON complete event" do
      download_fn = fn _url, _max_size, temp_path ->
        File.write!(temp_path, "hello")
        {:ok, temp_path, 5}
      end

      conn =
        conn(
          :get,
          "/download?key=happy1&url=http://example.com/file.txt&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init(download_fn: download_fn))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/x-ndjson; charset=utf-8"]

      chunks = collect_chunks(conn)
      assert length(chunks) == 2

      assert Jason.decode!(hd(chunks)) == %{"type" => "progress", "downloaded" => 5, "total" => 5}

      last = Jason.decode!(List.last(chunks))
      assert last["type"] == "complete"
      assert last["extracted"] == []
    end

    test "download exceeding max size returns error in NDJSON" do
      download_fn = fn _url, _max_size, temp_path ->
        File.write!(temp_path, "x")
        {:error, :too_large}
      end

      conn =
        conn(
          :get,
          "/download?key=big1&url=http://example.com/huge.bin&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init(download_fn: download_fn))

      assert conn.status == 200

      chunks = collect_chunks(conn)
      last = Jason.decode!(List.last(chunks))
      assert last["type"] == "error"
      assert last["message"] == "download exceeds 100MB"
    end

    test "download failure returns error in NDJSON" do
      download_fn = fn _url, _max_size, _temp_path ->
        {:error, {:http_error, 500}}
      end

      conn =
        conn(
          :get,
          "/download?key=fail1&url=http://example.com/fail.bin&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init(download_fn: download_fn))

      assert conn.status == 200

      chunks = collect_chunks(conn)
      last = Jason.decode!(List.last(chunks))
      assert last["type"] == "error"
      assert last["message"] == "HTTP error 500"
    end
  end

  describe "GET /download ETS cache" do
    test "same key reuses completed result for waiter" do
      download_fn = fn _url, _max_size, temp_path ->
        File.write!(temp_path, "cached content")
        {:ok, temp_path, 14}
      end

      # First request — primary downloader.
      conn1 =
        conn(
          :get,
          "/download?key=shared&url=http://example.com/f.txt&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init(download_fn: download_fn))

      assert conn1.status == 200

      # Second request — waiter, should get cached JSON response.
      conn2 =
        conn(
          :get,
          "/download?key=shared&url=http://example.com/f.txt&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init(download_fn: download_fn))

      assert conn2.status == 200
      body = Jason.decode!(conn2.resp_body)
      assert body["status"] == "complete"
      assert body["extracted"] == []
    end
  end

  describe "GET /download extraction" do
    test "extracts tar.gz fixture and lists files" do
      extract_dir =
        Path.join(System.tmp_dir!(), "weft-test-tar-#{System.unique_integer([:positive])}")

      download_fn = fn _url, _max_size, temp_path ->
        File.cp!(@tar_fixture, temp_path)
        {:ok, temp_path, File.stat!(temp_path).size}
      end

      conn =
        conn(
          :get,
          "/download?key=tar1&url=http://example.com/s.tar.gz&extract=#{extract_dir}&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init(download_fn: download_fn))

      assert conn.status == 200

      chunks = collect_chunks(conn)
      last = Jason.decode!(List.last(chunks))
      assert last["type"] == "complete"
      assert "tar_hello.txt" in last["extracted"]

      # Verify content was extracted.
      extracted_file = Path.join(extract_dir, "tar_hello.txt")
      assert File.read!(extracted_file) =~ "hello from tar.gz"

      # Cleanup.
      File.rm_rf!(extract_dir)
    end

    test "extracts zip fixture and lists files" do
      extract_dir =
        Path.join(System.tmp_dir!(), "weft-test-zip-#{System.unique_integer([:positive])}")

      download_fn = fn _url, _max_size, temp_path ->
        File.cp!(@zip_fixture, temp_path)
        {:ok, temp_path, File.stat!(temp_path).size}
      end

      conn =
        conn(
          :get,
          "/download?key=zip1&url=http://example.com/s.zip&extract=#{extract_dir}&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init(download_fn: download_fn))

      assert conn.status == 200

      chunks = collect_chunks(conn)
      last = Jason.decode!(List.last(chunks))
      assert last["type"] == "complete"
      assert "tar_hello.txt" in last["extracted"]

      extracted_file = Path.join(extract_dir, "tar_hello.txt")
      assert File.read!(extracted_file) =~ "hello from tar.gz"

      File.rm_rf!(extract_dir)
    end

    test "extraction path traversal in archive returns 502" do
      extract_dir =
        Path.join(System.tmp_dir!(), "weft-test-bad-#{System.unique_integer([:positive])}")

      extract_fn = fn _archive_path, _extract_path, _opts ->
        {:error, :path_traversal_in_archive}
      end

      download_fn = fn _url, _max_size, temp_path ->
        File.write!(temp_path, "fake archive")
        {:ok, temp_path, 12}
      end

      conn =
        conn(
          :get,
          "/download?key=badarch&url=http://example.com/bad.tgz&extract=#{extract_dir}&token=test-token-16chars-ok"
        )
        |> Download.call(Download.init(download_fn: download_fn, extract_fn: extract_fn))

      assert conn.status == 200

      chunks = collect_chunks(conn)
      last = Jason.decode!(List.last(chunks))
      assert last["type"] == "error"
      assert last["message"] == "path traversal detected in archive"
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp collect_chunks(conn) do
    # In Plug.Test mode, chunked bodies are accumulated as an iolist in
    # resp_body when the adapter supports it.  Bandit's test adapter stores
    # the concatenated binary.
    body =
      case conn.resp_body do
        nil -> ""
        bin when is_binary(bin) -> bin
        list when is_list(list) -> IO.iodata_to_binary(list)
        _ -> ""
      end

    body
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == ""))
  end
end
