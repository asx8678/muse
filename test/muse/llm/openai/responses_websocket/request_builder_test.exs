defmodule Muse.LLM.OpenAI.ResponsesWebsocket.RequestBuilderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request}
  alias Muse.LLM.OpenAI.ResponsesWebsocket.RequestBuilder

  # ---------------------------------------------------------------------------
  # URL derivation — https → wss
  # ---------------------------------------------------------------------------

  describe "build/1 — URL derivation https → wss" do
    test "derives wss URL from https base_url" do
      request = minimal_request("https://api.openai.com/v1")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "wss://api.openai.com/v1/responses"
    end

    test "derives wss URL from https base_url with trailing slash" do
      request = minimal_request("https://api.openai.com/v1/")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "wss://api.openai.com/v1/responses"
    end

    test "derives wss URL from https base_url with multiple trailing slashes" do
      request = minimal_request("https://api.openai.com/v1///")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "wss://api.openai.com/v1/responses"
    end

    test "endpoint_path matches ResponsesMapper" do
      request = minimal_request("https://api.openai.com/v1")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.endpoint_path == "/responses"
    end
  end

  # ---------------------------------------------------------------------------
  # URL derivation — http → ws
  # ---------------------------------------------------------------------------

  describe "build/1 — URL derivation http → ws" do
    test "derives ws URL from http base_url" do
      request = minimal_request("http://localhost:8080/v1")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "ws://localhost:8080/v1/responses"
    end

    test "derives ws URL from http base_url with trailing slash" do
      request = minimal_request("http://localhost:8080/v1/")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "ws://localhost:8080/v1/responses"
    end

    test "derives ws URL from http base_url with port" do
      request = minimal_request("http://127.0.0.1:3000")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "ws://127.0.0.1:3000/responses"
    end
  end

  # ---------------------------------------------------------------------------
  # Explicit websocket_url override
  # ---------------------------------------------------------------------------

  describe "build/1 — explicit websocket_url override" do
    test "uses explicit wss websocket_url from atom key" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: "wss://custom.ws.example.com/ws/responses"
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "wss://custom.ws.example.com/ws/responses"
    end

    test "uses explicit ws websocket_url from string key" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          "base_url" => "https://api.openai.com/v1",
          "websocket_url" => "ws://localhost:9000/responses"
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "ws://localhost:9000/responses"
    end

    test "explicit websocket_url takes precedence over base_url derivation" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: "wss://override.example.com/v1/responses"
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "wss://override.example.com/v1/responses"
    end

    test "accepts wss URL with port" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: "wss://ws.example.com:8443/v1/responses"
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.websocket_url == "wss://ws.example.com:8443/v1/responses"
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid / missing URL cases
  # ---------------------------------------------------------------------------

  describe "build/1 — invalid or missing base_url" do
    test "returns error when base_url is missing" do
      request = %Request{minimal_request(nil) | options: %{}}

      assert {:error, {:missing_base_url, msg}} = RequestBuilder.build(request)
      assert is_binary(msg)
    end

    test "returns error when base_url is nil" do
      request = minimal_request(nil)

      assert {:error, {:missing_base_url, _msg}} = RequestBuilder.build(request)
    end

    test "returns error when base_url is empty string" do
      request = minimal_request("")

      assert {:error, {:missing_base_url, _msg}} = RequestBuilder.build(request)
    end

    test "returns error for ftp scheme base_url" do
      request = minimal_request("ftp://files.example.com/models")

      assert {:error, {:invalid_base_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "http or https"
    end

    test "returns error for non-string base_url" do
      request = %Request{minimal_request(nil) | options: %{base_url: 12345}}

      assert {:error, {:invalid_base_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "must be a string"
    end

    test "returns error when base_url has no host" do
      request = minimal_request("https:///responses")

      assert {:error, {:invalid_base_url, _msg}} = RequestBuilder.build(request)
    end

    test "returns error for javascript scheme base_url" do
      request = minimal_request("javascript:alert(1)")

      assert {:error, {:invalid_base_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "http or https"
    end

    test "returns error for base_url with embedded credentials" do
      request = minimal_request("https://user:pass@api.example.com/v1")

      assert {:error, {:invalid_base_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "credentials"
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid websocket_url
  # ---------------------------------------------------------------------------

  describe "build/1 — invalid websocket_url" do
    test "returns error for non-string websocket_url" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: 12345
        })

      assert {:error, {:invalid_websocket_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "must be a string"
    end

    test "returns error for empty websocket_url" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: ""
        })

      assert {:error, {:missing_websocket_url, _msg}} = RequestBuilder.build(request)
    end

    test "returns error for http scheme websocket_url" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: "http://example.com/responses"
        })

      assert {:error, {:invalid_websocket_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "ws or wss"
    end

    test "returns error for https scheme websocket_url" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: "https://example.com/responses"
        })

      assert {:error, {:invalid_websocket_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "ws or wss"
    end

    test "returns error for websocket_url with no host" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: "wss:///responses"
        })

      assert {:error, {:invalid_websocket_url, _msg}} = RequestBuilder.build(request)
    end

    test "returns error for websocket_url with userinfo credentials" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: "wss://user:pass@ws.example.com/v1/responses"
        })

      assert {:error, {:invalid_websocket_url, msg}} = RequestBuilder.build(request)
      assert msg =~ "credentials"
    end
  end

  # ---------------------------------------------------------------------------
  # wire_api validation
  # ---------------------------------------------------------------------------

  describe "build/1 — wire_api validation" do
    test "accepts nil wire_api" do
      request = %Request{minimal_request("https://api.example.com/v1") | wire_api: nil}

      assert {:ok, _spec} = RequestBuilder.build(request)
    end

    test "accepts :responses wire_api" do
      request = %Request{
        minimal_request("https://api.example.com/v1")
        | wire_api: :responses
      }

      assert {:ok, _spec} = RequestBuilder.build(request)
    end

    test "rejects :chat_completions wire_api with clear error" do
      request = %Request{
        minimal_request("https://api.example.com/v1")
        | wire_api: :chat_completions
      }

      assert {:error, {:unsupported_wire_api, :chat_completions}} =
               RequestBuilder.build(request)
    end

    test "rejects unknown wire_api atom" do
      request = %Request{
        minimal_request("https://api.example.com/v1")
        | wire_api: :unknown_api
      }

      assert {:error, {:unsupported_wire_api, :unknown_api}} =
               RequestBuilder.build(request)
    end
  end

  # ---------------------------------------------------------------------------
  # response.create frame
  # ---------------------------------------------------------------------------

  describe "build/1 — response.create frame" do
    test "frame has type response.create and response key with payload" do
      request = minimal_request("https://api.openai.com/v1")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.frame["type"] == "response.create"
      assert is_map(spec.frame["response"])
    end

    test "frame response includes model from ResponsesMapper" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | model: "gpt-4.1"
      }

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.frame["response"]["model"] == "gpt-4.1"
    end

    test "frame response includes input from ResponsesMapper" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | messages: [Message.user("hello")]
      }

      assert {:ok, spec} = RequestBuilder.build(request)
      assert [%{"type" => "message", "role" => "user"}] = spec.frame["response"]["input"]
    end

    test "frame response includes tools from ResponsesMapper" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "test_tool", "parameters" => %{}}
            }
          ]
      }

      assert {:ok, spec} = RequestBuilder.build(request)

      assert [%{"type" => "function", "name" => "test_tool"}] =
               spec.frame["response"]["tools"]
    end

    test "frame response includes previous_response_id from ResponsesMapper" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | previous_response_id: "resp_abc123"
      }

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.frame["response"]["previous_response_id"] == "resp_abc123"
    end

    test "frame response retains stream => true from mapper" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | stream: true
      }

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.frame["response"]["stream"] == true
    end

    test "frame response retains store => false default from mapper" do
      request = minimal_request("https://api.openai.com/v1")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.frame["response"]["store"] == false
    end

    test "frame with full request includes all ResponsesMapper fields" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | model: "gpt-4.1",
          messages: [
            Message.system("Be helpful."),
            Message.user("hello")
          ],
          tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "run", "parameters" => %{}}
            }
          ],
          previous_response_id: "resp_prev",
          temperature: 0.5,
          max_tokens: 512
      }

      assert {:ok, spec} = RequestBuilder.build(request)
      response = spec.frame["response"]

      assert response["model"] == "gpt-4.1"
      assert is_list(response["input"])
      assert response["instructions"] == "Be helpful."
      assert is_list(response["tools"])
      assert response["previous_response_id"] == "resp_prev"
      assert response["temperature"] == 0.5
      assert response["max_output_tokens"] == 512
      assert response["stream"] == true
      assert response["store"] == false
    end
  end

  # ---------------------------------------------------------------------------
  # Headers
  # ---------------------------------------------------------------------------

  describe "build/1 — headers" do
    test "passes through map headers with string keys" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          headers: %{"X-Custom" => "value", "Accept" => "application/json"}
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert {"Accept", "application/json"} in spec.headers
      assert {"X-Custom", "value"} in spec.headers
    end

    test "passes through map headers with atom keys normalized to strings" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          headers: %{x_custom: "value"}
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert {"x_custom", "value"} in spec.headers
    end

    test "passes through list headers" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          headers: [{"X-Request-Id", "abc"}, {"Accept", "text/event-stream"}]
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert {"Accept", "text/event-stream"} in spec.headers
      assert {"X-Request-Id", "abc"} in spec.headers
    end

    test "returns empty headers when none provided" do
      request = minimal_request("https://api.openai.com/v1")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.headers == []
    end

    test "reads headers from string-key options" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          "base_url" => "https://api.openai.com/v1",
          "headers" => %{"X-From-String" => "yes"}
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert {"X-From-String", "yes"} in spec.headers
    end

    test "does not synthesize Authorization headers" do
      request = minimal_request("https://api.openai.com/v1")

      assert {:ok, spec} = RequestBuilder.build(request)
      refute Enum.any?(spec.headers, fn {k, _v} -> k == "Authorization" end)
    end

    test "skips header entries with non-string values" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          headers: %{"X-Valid" => "ok", "X-Invalid" => 123, "X-Also-Invalid" => nil}
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert {"X-Valid", "ok"} in spec.headers
      refute Enum.any?(spec.headers, fn {k, _} -> k == "X-Invalid" end)
      refute Enum.any?(spec.headers, fn {k, _} -> k == "X-Also-Invalid" end)
    end

    test "headers are sorted" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          headers: [{"Z-Last", "z"}, {"A-First", "a"}, {"M-Middle", "m"}]
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      keys = Enum.map(spec.headers, fn {k, _} -> k end)
      assert keys == Enum.sort(keys)
    end
  end

  # ---------------------------------------------------------------------------
  # No env var / auth synthesis
  # ---------------------------------------------------------------------------

  describe "build/1 — no env var or auth synthesis" do
    test "does not read MUSE_OPENAI_API_KEY" do
      original = System.get_env("MUSE_OPENAI_API_KEY")
      System.put_env("MUSE_OPENAI_API_KEY", "sk-test-canary-not-real")

      request = minimal_request("https://api.openai.com/v1")

      assert {:ok, spec} = RequestBuilder.build(request)

      refute Enum.any?(spec.headers, fn {k, _} -> k =~ ~r/authorization|api.key/i end)

      if original do
        System.put_env("MUSE_OPENAI_API_KEY", original)
      else
        System.delete_env("MUSE_OPENAI_API_KEY")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Request options forwarded
  # ---------------------------------------------------------------------------

  describe "build/1 — request options forwarded" do
    test "includes timeout_ms in connect_options when valid" do
      request = minimal_request("https://api.openai.com/v1", %{timeout_ms: 30_000})

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.connect_options[:timeout_ms] == 30_000
    end

    test "includes timeout_ms from string-key options in connect_options" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          "base_url" => "https://api.openai.com/v1",
          "timeout_ms" => 45_000
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.connect_options[:timeout_ms] == 45_000
    end

    test "omits timeout_ms from connect_options when zero" do
      request = minimal_request("https://api.openai.com/v1", %{timeout_ms: 0})

      assert {:ok, spec} = RequestBuilder.build(request)
      refute Keyword.has_key?(spec.connect_options, :timeout_ms)
    end

    test "omits timeout_ms from connect_options when negative" do
      request = minimal_request("https://api.openai.com/v1", %{timeout_ms: -100})

      assert {:ok, spec} = RequestBuilder.build(request)
      refute Keyword.has_key?(spec.connect_options, :timeout_ms)
    end

    test "omits timeout_ms from connect_options when non-integer" do
      request = minimal_request("https://api.openai.com/v1", %{timeout_ms: "slow"})

      assert {:ok, spec} = RequestBuilder.build(request)
      refute Keyword.has_key?(spec.connect_options, :timeout_ms)
    end

    test "includes receive_timeout in req_options when valid" do
      request = minimal_request("https://api.openai.com/v1", %{receive_timeout: 60_000})

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.req_options[:receive_timeout] == 60_000
    end

    test "includes receive_timeout from string-key options" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          "base_url" => "https://api.openai.com/v1",
          "receive_timeout" => 90_000
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.req_options[:receive_timeout] == 90_000
    end

    test "omits receive_timeout when zero" do
      request = minimal_request("https://api.openai.com/v1", %{receive_timeout: 0})

      assert {:ok, spec} = RequestBuilder.build(request)
      refute Keyword.has_key?(spec.req_options, :receive_timeout)
    end

    test "includes max_retries in req_options when valid non-negative integer" do
      request = minimal_request("https://api.openai.com/v1", %{max_retries: 3})

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.req_options[:max_retries] == 3
    end

    test "includes max_retries when zero" do
      request = minimal_request("https://api.openai.com/v1", %{max_retries: 0})

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.req_options[:max_retries] == 0
    end

    test "includes max_retries from string-key options" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          "base_url" => "https://api.openai.com/v1",
          "max_retries" => 2
        })

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.req_options[:max_retries] == 2
    end

    test "omits max_retries when negative" do
      request = minimal_request("https://api.openai.com/v1", %{max_retries: -1})

      assert {:ok, spec} = RequestBuilder.build(request)
      refute Keyword.has_key?(spec.req_options, :max_retries)
    end

    test "omits max_retries when non-integer" do
      request = minimal_request("https://api.openai.com/v1", %{max_retries: :forever})

      assert {:ok, spec} = RequestBuilder.build(request)
      refute Keyword.has_key?(spec.req_options, :max_retries)
    end

    test "returns empty connect_options and req_options when no valid options" do
      request = minimal_request("https://api.openai.com/v1")

      assert {:ok, spec} = RequestBuilder.build(request)
      assert spec.connect_options == []
      assert spec.req_options == []
    end
  end

  # ---------------------------------------------------------------------------
  # JSON safety
  # ---------------------------------------------------------------------------

  describe "build/1 — JSON safety" do
    test "frame is Jason-encodable" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | model: "gpt-4.1",
          messages: [
            Message.system("be helpful"),
            Message.user("hello")
          ],
          tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "test", "parameters" => %{}},
              :name => "test"
            }
          ],
          tool_choice: :auto,
          temperature: 0.7,
          max_tokens: 1000,
          previous_response_id: "resp_abc",
          stream: true
      }

      assert {:ok, spec} = RequestBuilder.build(request)
      json = Jason.encode!(spec.frame)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["type"] == "response.create"
      assert decoded["response"]["model"] == "gpt-4.1"
    end

    test "frame has no atom keys" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | model: "gpt-4.1",
          messages: [Message.user("hello")]
      }

      assert {:ok, spec} = RequestBuilder.build(request)
      assert_no_atom_keys!(spec.frame)
    end

    test "frame does not contain metadata or options keys" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          headers: %{"X-Foo" => "bar"}
        })

      request = %{request | metadata: %{internal: "secret"}}

      assert {:ok, spec} = RequestBuilder.build(request)
      refute Map.has_key?(spec.frame["response"], "metadata")
      refute Map.has_key?(spec.frame["response"], "options")
    end

    test "all payload keys are string-safe" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | model: "gpt-4.1",
          messages: [Message.user("hello")],
          tools: [
            %{
              "type" => "function",
              "function" => %{
                "name" => "list_files",
                "parameters" => %{type: "object", properties: %{}}
              }
            }
          ],
          previous_response_id: "resp_prev",
          temperature: 1.0,
          max_tokens: 256,
          response_format: %{type: "json_object"}
      }

      assert {:ok, spec} = RequestBuilder.build(request)
      response = spec.frame["response"]
      assert_no_atom_keys!(response)

      # Also verify the full frame (type, response wrapper) is string-keyed
      assert_no_atom_keys!(spec.frame)
    end
  end

  # ---------------------------------------------------------------------------
  # Error safety — no credential leakage
  # ---------------------------------------------------------------------------

  describe "build/1 — error safety" do
    test "error messages do not include header values" do
      request =
        minimal_request("ftp://bad.example.com", %{
          headers: %{"Authorization" => "Bearer sk-super-secret-key"}
        })

      assert {:error, reason} = RequestBuilder.build(request)
      inspected = inspect(reason)

      refute inspected =~ "sk-super-secret-key",
             "Error reason leaked header value: #{inspected}"

      refute inspected =~ "Bearer",
             "Error reason leaked header value: #{inspected}"
    end

    test "websocket_url error does not leak credentials" do
      request =
        minimal_request("https://api.openai.com/v1", %{
          websocket_url: "wss://user:secret@ws.example.com/v1/responses"
        })

      assert {:error, reason} = RequestBuilder.build(request)
      inspected = inspect(reason)

      refute inspected =~ "secret",
             "Error reason leaked credential: #{inspected}"
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp minimal_request(base_url, extra_options \\ %{}) do
    %Request{
      model: "gpt-4.1",
      messages: [Message.user("test")],
      options: options_with_base_url(base_url, extra_options)
    }
  end

  defp options_with_base_url(nil, extra), do: extra

  defp options_with_base_url(base_url, extra) when is_binary(base_url) do
    Map.merge(%{base_url: base_url}, extra)
  end

  # Recursively assert that a term contains no atom keys in any map.
  defp assert_no_atom_keys!(value) when is_map(value) do
    Enum.each(value, fn {key, nested_value} ->
      refute is_atom(key),
             "expected no atom keys, got #{inspect(key)} in #{inspect(value)}"

      assert_no_atom_keys!(nested_value)
    end)
  end

  defp assert_no_atom_keys!(value) when is_list(value) do
    Enum.each(value, &assert_no_atom_keys!/1)
  end

  defp assert_no_atom_keys!(_value), do: :ok
end
