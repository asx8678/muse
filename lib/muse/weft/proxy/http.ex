defmodule Muse.Weft.Proxy.Http do
  @moduledoc """
  HTTP forward proxy for Weft channels.

  ## Endpoint

      POST /proxy?url=<target>&token=<token>

  ## Authentication

  Uses `MuseWeb.ExternalSocketAuth` with a `token` query parameter.

  ## Opt-in

  The proxy is active only when enabled in config:

      config :muse, :weft, enabled_channels: ["proxy"]
  """

  @behaviour Plug

  import Plug.Conn

  alias MuseWeb.ExternalSocketAuth

  @default_timeout 30_000
  @max_timeout 60_000

  @denied_request_headers [
    "host",
    "connection",
    "keep-alive",
    "proxy-connection",
    "proxy-authorization",
    "transfer-encoding",
    "content-length",
    "cookie",
    "upgrade",
    "te",
    "trailer"
  ]

  @denied_response_headers [
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade"
  ]

  @impl Plug
  def init(opts) do
    opts
    |> Keyword.put_new(:timeout, @default_timeout)
    |> Keyword.put_new(:http_request_fn, &Req.request/1)
  end

  @impl Plug
  def call(conn, opts) do
    if not proxy_enabled?() do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{"error" => "proxy_disabled"}))
      |> halt()
    else
      conn = fetch_query_params(conn)

      with {:ok, conn} <- require_url(conn),
           {:ok, url} <- validate_url(conn.query_params["url"]),
           {:ok, conn} <- authenticate(conn),
           {:ok, body, conn} <- read_request_body(conn),
           {:ok, response} <- proxy_request(conn, url, body, opts) do
        send_proxy_response(conn, response)
      else
        {:error, :missing_url} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{"error" => "missing_url"}))
          |> halt()

        {:error, :invalid_url} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{"error" => "invalid_url"}))
          |> halt()

        {:error, :unauthorized} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
          |> halt()

        {:error, :bad_request} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{"error" => "bad_request"}))
          |> halt()

        {:error, :upstream_timeout} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            504,
            Jason.encode!(%{"error" => "upstream_timeout", "url" => "<redacted>"})
          )
          |> halt()

        {:error, :tls_error, detail} ->
          conn
          |> put_resp_header("x-weft-error", to_string(detail))
          |> put_resp_content_type("application/json")
          |> send_resp(
            502,
            Jason.encode!(%{"error" => "tls_error", "detail" => to_string(detail)})
          )
          |> halt()

        {:error, :proxy_error} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(502, Jason.encode!(%{"error" => "proxy_error"}))
          |> halt()
      end
    end
  end

  # -- Config ------------------------------------------------------------------

  defp proxy_enabled? do
    Application.get_env(:muse, :weft, [])
    |> Keyword.get(:enabled_channels, [])
    |> Enum.member?("proxy")
  end

  # -- URL validation ----------------------------------------------------------

  defp require_url(conn) do
    if is_nil(conn.query_params["url"]) or conn.query_params["url"] == "" do
      {:error, :missing_url}
    else
      {:ok, conn}
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

  defp validate_url(_url), do: {:error, :invalid_url}

  # -- Authentication ----------------------------------------------------------

  defp authenticate(conn) do
    token = conn.query_params["token"]

    case ExternalSocketAuth.authenticate(%{"token" => token}) do
      {:ok, _principal} -> {:ok, conn}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  # -- Body reading ------------------------------------------------------------

  defp read_request_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _data, _conn} -> {:error, :bad_request}
      {:error, :timeout} -> {:error, :bad_request}
      {:error, _reason} -> {:error, :bad_request}
    end
  end

  # -- Proxy request -----------------------------------------------------------

  defp proxy_request(conn, url, body, opts) do
    timeout =
      opts
      |> Keyword.get(:timeout, @default_timeout)
      |> min(@max_timeout)

    http_request_fn = Keyword.get(opts, :http_request_fn, &Req.request/1)

    headers = filter_request_headers(conn.req_headers)
    method = normalize_method(conn.method)

    req_opts = [
      url: url,
      method: method,
      headers: headers,
      body: body,
      decode_body: false,
      connect_options: [timeout: timeout],
      receive_timeout: timeout
    ]

    case do_request(http_request_fn, req_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: :econnrefused} = error} ->
        uri = URI.parse(url)

        if localhost_retryable?(uri.host) do
          retry_url = replace_host(uri, "127.0.0.1")
          retry_opts = Keyword.put(req_opts, :url, retry_url)
          do_request(http_request_fn, retry_opts) |> classify_transport_error()
        else
          classify_transport_error({:error, error})
        end

      other ->
        classify_transport_error(other)
    end
  end

  defp do_request(http_request_fn, req_opts) do
    http_request_fn.(req_opts)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp classify_transport_error({:ok, response}), do: {:ok, response}

  defp classify_transport_error({:error, %Req.TransportError{reason: :timeout}}) do
    {:error, :upstream_timeout}
  end

  defp classify_transport_error({:error, %Req.TransportError{reason: reason}}) do
    if tls_or_conn_error?(reason) do
      {:error, :tls_error, tls_error_detail(reason)}
    else
      {:error, :proxy_error}
    end
  end

  defp classify_transport_error({:error, %{__struct__: struct_name} = _error}) do
    struct_str = to_string(struct_name)

    if String.contains?(struct_str, "Transport") or
         String.contains?(struct_str, "TLS") or
         String.contains?(struct_str, "SSL") do
      {:error, :tls_error, "tls_error"}
    else
      {:error, :proxy_error}
    end
  end

  defp classify_transport_error({:error, _reason}), do: {:error, :proxy_error}

  defp filter_request_headers(headers) do
    Enum.reject(headers, fn {name, _value} -> name in @denied_request_headers end)
  end

  defp normalize_method(method) when is_binary(method) do
    method |> String.downcase() |> String.to_atom()
  end

  # -- Localhost retry ---------------------------------------------------------

  defp localhost_retryable?(host) when is_binary(host) do
    host == "localhost" or String.ends_with?(host, ".localhost")
  end

  defp localhost_retryable?(_host), do: false

  defp replace_host(%URI{} = uri, new_host) do
    URI.to_string(%{uri | host: new_host})
  end

  # -- TLS / connection error classification -----------------------------------

  defp tls_or_conn_error?(:nxdomain), do: true
  defp tls_or_conn_error?(:econnrefused), do: true
  defp tls_or_conn_error?(reason) when is_atom(reason), do: ssl_error?(reason)
  defp tls_or_conn_error?(_reason), do: false

  defp ssl_error?(reason) when is_atom(reason) do
    reason in [
      :bad_certificate,
      :unsupported_certificate,
      :certificate_revoked,
      :certificate_expired,
      :certificate_unknown,
      :unknown_ca,
      :handshake_failure,
      :protocol_version,
      :insufficient_security,
      :decrypt_error,
      :bad_record_mac,
      :protocol_not_negotiated,
      :closed
    ] or
      reason |> Atom.to_string() |> String.starts_with?("tls") or
      reason |> Atom.to_string() |> String.starts_with?("ssl")
  end

  defp ssl_error?(_reason), do: false

  defp tls_error_detail(:nxdomain), do: "nxdomain"
  defp tls_error_detail(:econnrefused), do: "econnrefused"
  defp tls_error_detail(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp tls_error_detail(_reason), do: "tls_error"

  # -- Response forwarding -----------------------------------------------------

  defp send_proxy_response(conn, %Req.Response{status: status, headers: headers, body: body}) do
    headers_list =
      for {name, values} <- headers,
          value <- values,
          name not in @denied_response_headers do
        {name, value}
      end

    body = body || ""

    conn
    |> merge_resp_headers(headers_list)
    |> send_resp(status, body)
    |> halt()
  end
end
