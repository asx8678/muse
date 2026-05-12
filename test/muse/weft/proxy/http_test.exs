defmodule Muse.Weft.Proxy.HttpTest do
  @moduledoc """
  Tests for the Weft HTTP forward proxy plug.

  All tests are fully offline — HTTP requests are injected via
  `http_request_fn` instead of real network calls.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Muse.Weft.Proxy.Http

  setup do
    original_weft = Application.get_env(:muse, :weft)
    Application.put_env(:muse, :weft, enabled_channels: ["proxy"])

    on_exit(fn ->
      if original_weft do
        Application.put_env(:muse, :weft, original_weft)
      else
        Application.delete_env(:muse, :weft)
      end
    end)

    :ok
  end

  describe "POST /proxy" do
    test "missing url returns 400" do
      conn =
        conn(:post, "/proxy?token=test-token-16chars-ok", "")
        |> Http.call(
          http_request_fn: fn _opts -> {:ok, Req.Response.new(status: 200, body: "ok")} end
        )

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "missing_url"}
    end

    test "invalid URL scheme returns 400" do
      conn =
        conn(:post, "/proxy?url=file:///etc/passwd&token=test-token-16chars-ok", "")
        |> Http.call(
          http_request_fn: fn _opts -> {:ok, Req.Response.new(status: 200, body: "ok")} end
        )

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_url"}
    end

    test "missing auth token returns 401" do
      conn =
        conn(:post, "/proxy?url=http://example.com", "")
        |> Http.call(
          http_request_fn: fn _opts -> {:ok, Req.Response.new(status: 200, body: "ok")} end
        )

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    end

    test "successful forward returns 200 with body and headers" do
      http_request_fn = fn opts ->
        assert opts[:url] == "http://example.com/api"
        assert opts[:method] == :post
        assert opts[:body] == ~s<{"key":"value"}>
        assert {"content-type", "application/json"} in opts[:headers]

        {:ok,
         Req.Response.new(
           status: 200,
           headers: %{"content-type" => ["text/plain"], "x-custom" => ["hello"]},
           body: "proxied response"
         )}
      end

      conn =
        conn(
          :post,
          "/proxy?url=http://example.com/api&token=test-token-16chars-ok",
          ~s<{"key":"value"}>
        )
        |> put_req_header("content-type", "application/json")
        |> Http.call(http_request_fn: http_request_fn)

      assert conn.status == 200
      assert conn.resp_body == "proxied response"
      assert {"content-type", "text/plain"} in conn.resp_headers
      assert {"x-custom", "hello"} in conn.resp_headers
    end

    test "downstream bad request is forwarded" do
      conn =
        conn(:post, "/proxy?url=http://example.com&token=test-token-16chars-ok", "")
        |> Http.call(
          http_request_fn: fn _opts ->
            {:ok, Req.Response.new(status: 400, body: "bad params")}
          end
        )

      assert conn.status == 400
      assert conn.resp_body == "bad params"
    end

    test "connection timeout returns 504 with redacted url" do
      conn =
        conn(:post, "/proxy?url=http://example.com&token=test-token-16chars-ok", "")
        |> Http.call(
          http_request_fn: fn _opts ->
            {:error, %Req.TransportError{reason: :timeout}}
          end
        )

      assert conn.status == 504

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "upstream_timeout",
               "url" => "<redacted>"
             }
    end

    test "TLS nxdomain returns 502 with typed X-Weft-Error header" do
      conn =
        conn(:post, "/proxy?url=http://example.com&token=test-token-16chars-ok", "")
        |> Http.call(
          http_request_fn: fn _opts ->
            {:error, %Req.TransportError{reason: :nxdomain}}
          end
        )

      assert conn.status == 502
      assert Jason.decode!(conn.resp_body) == %{"error" => "tls_error", "detail" => "nxdomain"}
      assert {"x-weft-error", "nxdomain"} in conn.resp_headers
    end

    test "TLS certificate error returns 502 with typed detail" do
      conn =
        conn(:post, "/proxy?url=http://example.com&token=test-token-16chars-ok", "")
        |> Http.call(
          http_request_fn: fn _opts ->
            {:error, %Req.TransportError{reason: :bad_certificate}}
          end
        )

      assert conn.status == 502

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "tls_error",
               "detail" => "bad_certificate"
             }

      assert {"x-weft-error", "bad_certificate"} in conn.resp_headers
    end

    test "generic proxy failure returns 502" do
      conn =
        conn(:post, "/proxy?url=http://example.com&token=test-token-16chars-ok", "")
        |> Http.call(http_request_fn: fn _opts -> {:error, :some_error} end)

      assert conn.status == 502
      assert Jason.decode!(conn.resp_body) == %{"error" => "proxy_error"}
    end

    test "proxy disabled returns 503" do
      Application.put_env(:muse, :weft, enabled_channels: [])

      conn =
        conn(:post, "/proxy?url=http://example.com&token=test-token-16chars-ok", "")
        |> Http.call(
          http_request_fn: fn _opts -> {:ok, Req.Response.new(status: 200, body: "ok")} end
        )

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"error" => "proxy_disabled"}
    end

    test "localhost retry on econnrefused" do
      call_count = :atomics.new(1, signed: false)

      http_request_fn = fn opts ->
        count = :atomics.add_get(call_count, 1, 1)

        if count == 1 do
          assert opts[:url] == "http://foo.localhost:8080/api"
          {:error, %Req.TransportError{reason: :econnrefused}}
        else
          assert opts[:url] == "http://127.0.0.1:8080/api"
          {:ok, Req.Response.new(status: 200, body: "retry ok")}
        end
      end

      conn =
        conn(:post, "/proxy?url=http://foo.localhost:8080/api&token=test-token-16chars-ok", "")
        |> Http.call(http_request_fn: http_request_fn)

      assert conn.status == 200
      assert conn.resp_body == "retry ok"
    end

    test "empty body is forwarded successfully" do
      http_request_fn = fn opts ->
        assert opts[:body] == ""
        {:ok, Req.Response.new(status: 204, body: "")}
      end

      conn =
        conn(:post, "/proxy?url=http://example.com&token=test-token-16chars-ok", "")
        |> Http.call(http_request_fn: http_request_fn)

      assert conn.status == 204
      assert conn.resp_body == ""
    end
  end
end
