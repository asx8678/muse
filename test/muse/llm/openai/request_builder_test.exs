defmodule Muse.LLM.OpenAI.RequestBuilderTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request}
  alias Muse.LLM.OpenAI.RequestBuilder

  # ---------------------------------------------------------------------------
  # build_chat_completions/1 — happy path
  # ---------------------------------------------------------------------------

  describe "build_chat_completions/1 — happy path" do
    test "builds URL from custom base_url" do
      request = minimal_request("https://api.example.com/v1")

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.url == "https://api.example.com/v1/chat/completions"
      assert spec.endpoint_path == "/chat/completions"
    end

    test "builds URL from base_url with trailing slash" do
      request = minimal_request("https://api.example.com/v1/")

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.url == "https://api.example.com/v1/chat/completions"
    end

    test "builds URL from base_url with multiple trailing slashes" do
      request = minimal_request("https://api.example.com/v1///")

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.url == "https://api.example.com/v1/chat/completions"
    end

    test "forces stream => false in payload" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | stream: true
      }

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.payload["stream"] == false
    end

    test "forces stream => false even when request.stream is false" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | stream: false
      }

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.payload["stream"] == false
    end

    test "payload contains model and messages from mapper" do
      request = %Request{
        minimal_request("https://api.openai.com/v1")
        | model: "gpt-4.1",
          messages: [Message.user("hello")]
      }

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.payload["model"] == "gpt-4.1"
      assert [%{"role" => "user", "content" => "hello"}] = spec.payload["messages"]
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions/1 — wire_api validation
  # ---------------------------------------------------------------------------

  describe "build_chat_completions/1 — wire_api validation" do
    test "accepts nil wire_api" do
      request = %Request{minimal_request("https://api.example.com/v1") | wire_api: nil}

      assert {:ok, _spec} = RequestBuilder.build_chat_completions(request)
    end

    test "accepts :chat_completions wire_api" do
      request = %Request{
        minimal_request("https://api.example.com/v1")
        | wire_api: :chat_completions
      }

      assert {:ok, _spec} = RequestBuilder.build_chat_completions(request)
    end

    test "rejects :responses wire_api with clear error" do
      request = %Request{
        minimal_request("https://api.example.com/v1")
        | wire_api: :responses
      }

      assert {:error, {:unsupported_wire_api, :responses}} =
               RequestBuilder.build_chat_completions(request)
    end

    test "rejects unknown wire_api atom" do
      request = %Request{
        minimal_request("https://api.example.com/v1")
        | wire_api: :unknown_api
      }

      assert {:error, {:unsupported_wire_api, :unknown_api}} =
               RequestBuilder.build_chat_completions(request)
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions/1 — base_url errors
  # ---------------------------------------------------------------------------

  describe "build_chat_completions/1 — base_url errors" do
    test "returns error when base_url is missing" do
      request = %Request{minimal_request(nil) | options: %{}}

      assert {:error, {:missing_base_url, msg}} = RequestBuilder.build_chat_completions(request)
      assert is_binary(msg)
    end

    test "returns error when base_url is nil" do
      request = minimal_request(nil)

      assert {:error, {:missing_base_url, _msg}} =
               RequestBuilder.build_chat_completions(request)
    end

    test "returns error when base_url is empty string" do
      request = minimal_request("")

      assert {:error, {:missing_base_url, _msg}} =
               RequestBuilder.build_chat_completions(request)
    end

    test "returns error for ftp scheme" do
      request = minimal_request("ftp://files.example.com/models")

      assert {:error, {:invalid_base_url, msg}} =
               RequestBuilder.build_chat_completions(request)

      assert msg =~ "http or https"
    end

    test "returns error for non-string base_url" do
      request = %Request{minimal_request(nil) | options: %{base_url: 12345}}

      assert {:error, {:invalid_base_url, msg}} =
               RequestBuilder.build_chat_completions(request)

      assert msg =~ "must be a string"
    end

    test "returns error when base_url has no host" do
      request = minimal_request("https:///chat/completions")

      assert {:error, {:invalid_base_url, _msg}} =
               RequestBuilder.build_chat_completions(request)
    end

    test "returns error for javascript scheme" do
      request = minimal_request("javascript:alert(1)")

      assert {:error, {:invalid_base_url, msg}} =
               RequestBuilder.build_chat_completions(request)

      assert msg =~ "http or https"
    end

    test "returns error for URL with embedded credentials" do
      request = minimal_request("https://user:pass@api.example.com/v1")

      assert {:error, {:invalid_base_url, msg}} =
               RequestBuilder.build_chat_completions(request)

      assert msg =~ "credentials"
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions/1 — headers
  # ---------------------------------------------------------------------------

  describe "build_chat_completions/1 — headers" do
    test "passes through map headers with string keys" do
      request =
        minimal_request("https://api.example.com/v1", %{
          headers: %{"X-Custom" => "value", "Accept" => "application/json"}
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert {"Accept", "application/json"} in spec.headers
      assert {"X-Custom", "value"} in spec.headers
    end

    test "passes through map headers with atom keys (normalized to strings)" do
      request =
        minimal_request("https://api.example.com/v1", %{
          headers: %{x_custom: "value"}
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert {"x_custom", "value"} in spec.headers
    end

    test "passes through list headers" do
      request =
        minimal_request("https://api.example.com/v1", %{
          headers: [{"X-Request-Id", "abc"}, {"Accept", "text/event-stream"}]
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert {"Accept", "text/event-stream"} in spec.headers
      assert {"X-Request-Id", "abc"} in spec.headers
    end

    test "returns empty headers when none provided" do
      request = minimal_request("https://api.example.com/v1")

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.headers == []
    end

    test "reads headers from string-key options" do
      request =
        minimal_request("https://api.example.com/v1", %{
          "base_url" => "https://api.example.com/v1",
          "headers" => %{"X-From-String" => "yes"}
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert {"X-From-String", "yes"} in spec.headers
    end

    test "does not synthesize auth headers" do
      request = minimal_request("https://api.example.com/v1")

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      refute Enum.any?(spec.headers, fn {k, _v} -> k == "Authorization" end)
    end

    test "skips header entries with non-string values" do
      request =
        minimal_request("https://api.example.com/v1", %{
          headers: %{"X-Valid" => "ok", "X-Invalid" => 123, "X-Also-Invalid" => nil}
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert {"X-Valid", "ok"} in spec.headers
      refute Enum.any?(spec.headers, fn {k, _} -> k == "X-Invalid" end)
      refute Enum.any?(spec.headers, fn {k, _} -> k == "X-Also-Invalid" end)
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions/1 — no env var / auth read
  # ---------------------------------------------------------------------------

  describe "build_chat_completions/1 — no env var or auth synthesis" do
    test "does not read MUSE_OPENAI_API_KEY" do
      # Set a canary env var; if the builder reads it, we'd see it in headers
      original = System.get_env("MUSE_OPENAI_API_KEY")
      System.put_env("MUSE_OPENAI_API_KEY", "sk-test-canary-not-real")

      request = minimal_request("https://api.example.com/v1")

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)

      # No Authorization or api-key header synthesized
      refute Enum.any?(spec.headers, fn {k, _} -> k =~ ~r/authorization|api.key/i end)

      # Restore
      if original do
        System.put_env("MUSE_OPENAI_API_KEY", original)
      else
        System.delete_env("MUSE_OPENAI_API_KEY")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions/1 — JSON safety
  # ---------------------------------------------------------------------------

  describe "build_chat_completions/1 — JSON safety" do
    test "payload is Jason-encodable" do
      request = %Request{
        minimal_request("https://api.example.com/v1")
        | model: "gpt-4.1",
          messages: [Message.system("be helpful"), Message.user("hello")],
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
          stream: true
      }

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      json = Jason.encode!(spec.payload)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["stream"] == false
      assert decoded["model"] == "gpt-4.1"
    end

    test "payload has no atom keys" do
      request = %Request{
        minimal_request("https://api.example.com/v1")
        | model: "gpt-4.1",
          messages: [Message.user("hello")]
      }

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert_no_atom_keys!(spec.payload)
    end

    test "payload does not contain metadata or options keys" do
      request =
        minimal_request("https://api.example.com/v1", %{
          headers: %{"X-Foo" => "bar"}
        })

      request = %{request | metadata: %{internal: "secret"}}

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      refute Map.has_key?(spec.payload, "metadata")
      refute Map.has_key?(spec.payload, "options")
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions/1 — req options
  # ---------------------------------------------------------------------------

  describe "build_chat_completions/1 — req options" do
    test "includes timeout_ms when valid positive integer" do
      request = minimal_request("https://api.example.com/v1", %{timeout_ms: 30_000})

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.req_options[:timeout_ms] == 30_000
    end

    test "includes timeout_ms from string-key options" do
      request =
        minimal_request("https://api.example.com/v1", %{
          "base_url" => "https://api.example.com/v1",
          "timeout_ms" => 45_000
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.req_options[:timeout_ms] == 45_000
    end

    test "omits timeout_ms when zero" do
      request = minimal_request("https://api.example.com/v1", %{timeout_ms: 0})

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      refute Keyword.has_key?(spec.req_options, :timeout_ms)
    end

    test "omits timeout_ms when negative" do
      request = minimal_request("https://api.example.com/v1", %{timeout_ms: -100})

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      refute Keyword.has_key?(spec.req_options, :timeout_ms)
    end

    test "omits timeout_ms when non-integer" do
      request = minimal_request("https://api.example.com/v1", %{timeout_ms: "slow"})

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      refute Keyword.has_key?(spec.req_options, :timeout_ms)
    end

    test "includes max_retries when valid non-negative integer" do
      request = minimal_request("https://api.example.com/v1", %{max_retries: 3})

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.req_options[:max_retries] == 3
    end

    test "includes max_retries when zero" do
      request = minimal_request("https://api.example.com/v1", %{max_retries: 0})

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.req_options[:max_retries] == 0
    end

    test "includes max_retries from string-key options" do
      request =
        minimal_request("https://api.example.com/v1", %{
          "base_url" => "https://api.example.com/v1",
          "max_retries" => 2
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.req_options[:max_retries] == 2
    end

    test "omits max_retries when negative" do
      request = minimal_request("https://api.example.com/v1", %{max_retries: -1})

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      refute Keyword.has_key?(spec.req_options, :max_retries)
    end

    test "omits max_retries when non-integer" do
      request = minimal_request("https://api.example.com/v1", %{max_retries: :forever})

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      refute Keyword.has_key?(spec.req_options, :max_retries)
    end

    test "returns empty req_options when no valid options" do
      request = minimal_request("https://api.example.com/v1")

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.req_options == []
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions/1 — headers not leaked in errors
  # ---------------------------------------------------------------------------

  describe "build_chat_completions/1 — error safety" do
    test "error messages do not include header values" do
      request =
        minimal_request("ftp://bad.example.com", %{
          headers: %{"Authorization" => "Bearer sk-super-secret-key"}
        })

      assert {:error, reason} = RequestBuilder.build_chat_completions(request)
      inspected = inspect(reason)

      refute inspected =~ "sk-super-secret-key",
             "Error reason leaked header value: #{inspected}"

      refute inspected =~ "Bearer",
             "Error reason leaked header value: #{inspected}"
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions_stream/1 — happy path
  # ---------------------------------------------------------------------------

  describe "build_chat_completions_stream/1 — happy path" do
    test "builds streaming URL, payload, and default SSE headers" do
      request = %Request{minimal_request("https://api.example.com/v1/") | stream: false}

      assert {:ok, spec} = RequestBuilder.build_chat_completions_stream(request)
      assert spec.url == "https://api.example.com/v1/chat/completions"
      assert spec.endpoint_path == "/chat/completions"
      assert spec.payload["stream"] == true
      assert spec.payload["stream_options"] == %{"include_usage" => true}
      assert {"Accept", "text/event-stream"} in spec.headers
    end

    test "non-streaming builder remains unchanged when stream_options are provided" do
      request =
        minimal_request("https://api.example.com/v1", %{
          stream_options: %{"include_usage" => true}
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions(request)
      assert spec.payload["stream"] == false
      refute Map.has_key?(spec.payload, "stream_options")
      assert spec.headers == []
    end

    test "uses caller stream_options override and normalizes atom keys" do
      request =
        minimal_request("https://api.example.com/v1", %{
          stream_options: %{include_usage: false, custom: %{mode: :compact}}
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions_stream(request)

      assert spec.payload["stream_options"] == %{
               "include_usage" => false,
               "custom" => %{"mode" => "compact"}
             }

      assert_no_atom_keys!(spec.payload)
    end

    test "allows string-key stream_options to disable stream_options payload field" do
      request =
        minimal_request("https://api.example.com/v1", %{
          "stream_options" => false
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions_stream(request)
      assert spec.payload["stream"] == true
      refute Map.has_key?(spec.payload, "stream_options")
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions_stream/1 — headers
  # ---------------------------------------------------------------------------

  describe "build_chat_completions_stream/1 — headers" do
    test "does not override caller Accept header regardless of casing" do
      request =
        minimal_request("https://api.example.com/v1", %{
          headers: [{"accept", "application/json"}, {"X-Request-Id", "abc"}]
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions_stream(request)
      assert {"accept", "application/json"} in spec.headers
      assert {"X-Request-Id", "abc"} in spec.headers
      refute {"Accept", "text/event-stream"} in spec.headers

      accept_count =
        Enum.count(spec.headers, fn {name, _value} -> String.downcase(name) == "accept" end)

      assert accept_count == 1
    end

    test "does not synthesize Authorization header" do
      request = minimal_request("https://api.example.com/v1")

      assert {:ok, spec} = RequestBuilder.build_chat_completions_stream(request)

      refute Enum.any?(spec.headers, fn {name, _value} ->
               String.downcase(name) == "authorization"
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # build_chat_completions_stream/1 — validation and Req options
  # ---------------------------------------------------------------------------

  describe "build_chat_completions_stream/1 — validation and Req options" do
    test "rejects unsupported wire_api exactly like non-streaming builder" do
      request = %Request{
        minimal_request("https://api.example.com/v1")
        | wire_api: :responses
      }

      assert {:error, {:unsupported_wire_api, :responses}} =
               RequestBuilder.build_chat_completions_stream(request)
    end

    test "returns missing base_url errors" do
      request = %Request{minimal_request(nil) | options: %{}}

      assert {:error, {:missing_base_url, msg}} =
               RequestBuilder.build_chat_completions_stream(request)

      assert is_binary(msg)
    end

    test "returns invalid base_url errors" do
      request = minimal_request("ftp://files.example.com/models")

      assert {:error, {:invalid_base_url, msg}} =
               RequestBuilder.build_chat_completions_stream(request)

      assert msg =~ "http or https"
    end

    test "carries timeout_ms and max_retries like non-streaming builder" do
      request =
        minimal_request("https://api.example.com/v1", %{
          timeout_ms: 30_000,
          max_retries: 2
        })

      assert {:ok, spec} = RequestBuilder.build_chat_completions_stream(request)
      assert spec.req_options[:timeout_ms] == 30_000
      assert spec.req_options[:max_retries] == 2
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
