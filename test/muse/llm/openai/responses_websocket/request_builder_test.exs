defmodule Muse.LLM.OpenAI.ResponsesWebSocket.RequestBuilderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.OpenAI.ResponsesWebSocket.RequestBuilder
  alias Muse.LLM.Request

  defp base_request(overrides \\ []) do
    defaults = [
      provider: :openai,
      model: "gpt-4.1",
      wire_api: :responses,
      messages: [],
      options: %{base_url: "https://api.openai.com/v1"}
    ]

    struct(Request, Keyword.merge(defaults, overrides))
  end

  describe "build/1 — basic" do
    test "builds a valid spec with derived wss URL from https base_url" do
      request = base_request()
      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "wss://api.openai.com/v1/responses"
      assert spec.endpoint_path == "/responses"
      assert spec.frame["type"] == "response.create"
      assert spec.frame["response"]["model"] == "gpt-4.1"
      assert spec.headers == []
    end

    test "builds spec with ws URL from http base_url" do
      request = base_request(options: %{base_url: "http://localhost:8080/v1"})
      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "ws://localhost:8080/v1/responses"
    end

    test "uses explicit websocket_url over derived URL" do
      request =
        base_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            websocket_url: "wss://custom.ws.example.com/responses"
          }
        )

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "wss://custom.ws.example.com/responses"
    end
  end

  describe "build/1 — wire_api validation" do
    test "accepts :responses wire_api" do
      request = base_request(wire_api: :responses)
      assert {:ok, _} = RequestBuilder.build(request)
    end

    test "accepts nil wire_api" do
      request = base_request(wire_api: nil)
      assert {:ok, _} = RequestBuilder.build(request)
    end

    test "rejects :chat_completions wire_api" do
      request = base_request(wire_api: :chat_completions)
      assert {:error, {:unsupported_wire_api, :chat_completions}} = RequestBuilder.build(request)
    end
  end

  describe "build/1 — base_url validation" do
    test "rejects missing base_url" do
      request = base_request(options: %{})
      assert {:error, {:missing_base_url, _}} = RequestBuilder.build(request)
    end

    test "rejects empty base_url" do
      request = base_request(options: %{base_url: ""})
      assert {:error, {:missing_base_url, _}} = RequestBuilder.build(request)
    end

    test "rejects non-string base_url" do
      request = base_request(options: %{base_url: 123})
      assert {:error, {:invalid_base_url, _}} = RequestBuilder.build(request)
    end

    test "rejects base_url with embedded credentials" do
      request = base_request(options: %{base_url: "https://user:pass@api.openai.com/v1"})
      assert {:error, {:invalid_base_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "userinfo"
    end

    test "rejects base_url with unsupported scheme" do
      request = base_request(options: %{base_url: "ftp://api.openai.com/v1"})
      assert {:error, {:invalid_base_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "REDACTED"
    end

    test "trims trailing slashes from base_url" do
      request = base_request(options: %{base_url: "https://api.openai.com/v1/"})
      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "wss://api.openai.com/v1/responses"
    end
  end

  describe "build/1 — explicit websocket_url validation" do
    test "rejects non-string websocket_url" do
      request = base_request(options: %{websocket_url: 123})
      assert {:error, {:invalid_websocket_url, _}} = RequestBuilder.build(request)
    end

    test "rejects empty websocket_url" do
      request = base_request(options: %{websocket_url: ""})
      assert {:error, {:missing_websocket_url, _}} = RequestBuilder.build(request)
    end

    test "rejects websocket_url with non-ws scheme" do
      request = base_request(options: %{websocket_url: "https://api.openai.com/v1/responses"})
      assert {:error, {:invalid_websocket_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "REDACTED"
    end

    test "rejects websocket_url with embedded credentials" do
      request =
        base_request(options: %{websocket_url: "wss://user:pass@api.openai.com/v1/responses"})

      assert {:error, {:invalid_websocket_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "userinfo"
    end
  end

  describe "build/1 — frame building" do
    test "frame has correct type and wraps response payload" do
      request = base_request()
      {:ok, spec} = RequestBuilder.build(request)
      assert spec.frame["type"] == "response.create"
      assert is_map(spec.frame["response"])
      assert spec.frame["response"]["model"] == "gpt-4.1"
    end
  end

  describe "build/1 — headers" do
    test "carries map headers as sorted keyword list" do
      request =
        base_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            headers: %{"X-Custom" => "value", "Accept" => "application/json"}
          }
        )

      {:ok, spec} = RequestBuilder.build(request)
      assert spec.headers == [{"Accept", "application/json"}, {"X-Custom", "value"}]
    end

    test "carries list headers as sorted keyword list" do
      request =
        base_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            headers: [{"Z-Last", "z"}, {"A-First", "a"}]
          }
        )

      {:ok, spec} = RequestBuilder.build(request)
      assert spec.headers == [{"A-First", "a"}, {"Z-Last", "z"}]
    end

    test "no auth headers are synthesized" do
      request = base_request()
      {:ok, spec} = RequestBuilder.build(request)
      refute Enum.any?(spec.headers, fn {name, _} -> String.downcase(name) == "authorization" end)
    end
  end

  describe "build/1 — options forwarding" do
    test "forwards timeout_ms" do
      request = base_request(options: %{base_url: "https://api.openai.com/v1", timeout_ms: 5000})
      {:ok, spec} = RequestBuilder.build(request)
      assert spec.connect_options[:timeout_ms] == 5000
    end

    test "forwards receive_timeout" do
      request =
        base_request(options: %{base_url: "https://api.openai.com/v1", receive_timeout: 30_000})

      {:ok, spec} = RequestBuilder.build(request)
      assert spec.req_options[:receive_timeout] == 30_000
    end

    test "forwards max_retries" do
      request = base_request(options: %{base_url: "https://api.openai.com/v1", max_retries: 2})
      {:ok, spec} = RequestBuilder.build(request)
      assert spec.req_options[:max_retries] == 2
    end

    test "ignores invalid option values" do
      request =
        base_request(
          options: %{
            base_url: "https://api.openai.com/v1",
            timeout_ms: -1,
            receive_timeout: "bad",
            max_retries: -5
          }
        )

      {:ok, spec} = RequestBuilder.build(request)
      assert spec.connect_options == []
      assert spec.req_options == []
    end
  end

  describe "build/1 — secrets never leak" do
    test "error messages never contain full URLs" do
      request = base_request(options: %{base_url: "ftp://secret-url.example.com/v1"})
      {:error, {:invalid_base_url, msg}} = RequestBuilder.build(request)
      refute msg =~ "secret-url"
      assert msg =~ "REDACTED"
    end
  end
end
