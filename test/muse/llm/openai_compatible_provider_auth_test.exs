defmodule Muse.LLM.OpenAICompatibleProviderAuthTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request}
  alias Muse.LLM.OpenAICompatibleProvider

  describe "complete/2 auth integration" do
    test "injects Authorization header from configured api_key auth" do
      parent = self()

      post_fn = fn url, options ->
        send(parent, {:post_called, url, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request =
        request(%{
          auth: :api_key,
          env_key: "MUSE_TEST_API_KEY",
          auth_env: %{"MUSE_TEST_API_KEY" => "sk-provider-secret"},
          system_env?: false
        })

      assert {:ok, response} = OpenAICompatibleProvider.complete(request, post_fn: post_fn)
      assert response.content == "authenticated hello"

      assert_receive {:post_called, "https://api.example.test/v1/chat/completions", options}
      assert {"Authorization", "Bearer sk-provider-secret"} in options[:headers]
      assert authorization_headers(options[:headers]) == ["Bearer sk-provider-secret"]
    end

    test "explicit Authorization header wins and resolver does not duplicate or require env" do
      parent = self()

      post_fn = fn _url, options ->
        send(parent, {:post_called, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request =
        request(%{
          auth: :api_key,
          env_key: "MUSE_TEST_API_KEY",
          env: %{},
          system_env?: false,
          headers: [{"Authorization", "Bearer caller-secret"}, {"X-Custom", "ok"}]
        })

      assert {:ok, _response} = OpenAICompatibleProvider.complete(request, post_fn: post_fn)

      assert_receive {:post_called, options}
      assert authorization_headers(options[:headers]) == ["Bearer caller-secret"]
      assert {"X-Custom", "ok"} in options[:headers]
    end

    test "missing configured auth returns auth_error before post_fn is called" do
      post_fn = fn url, options ->
        send(self(), {:unexpected_post, url, options})
        {:ok, Req.Response.new(status: 200, body: text_body())}
      end

      request =
        request(%{
          auth: :api_key,
          env_key: "MUSE_TEST_API_KEY",
          env: %{},
          system_env?: false
        })

      assert {:error, {:auth_error, {:missing, "MUSE_TEST_API_KEY"}}} =
               OpenAICompatibleProvider.complete(request, post_fn: post_fn)

      refute_received {:unexpected_post, _url, _options}
    end

    test "provider network errors with auth configured do not leak key or Bearer header" do
      post_fn = fn _url, options ->
        {:error, {:transport_failed, options}}
      end

      request =
        request(%{
          auth: :api_key,
          env_key: "MUSE_TEST_API_KEY",
          auth_env: %{"MUSE_TEST_API_KEY" => "sk-network-secret"},
          system_env?: false
        })

      assert {:error, {:provider_network_error, %{reason: reason}}} =
               OpenAICompatibleProvider.complete(request, post_fn: post_fn)

      rendered = inspect(reason)
      refute rendered =~ "sk-network-secret"
      refute rendered =~ "Bearer sk-network"
      assert rendered =~ "REDACTED" or rendered =~ "**REDACTED**"
    end
  end

  defp request(extra_options) do
    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :chat_completions,
      transport: :none,
      messages: [Message.user("hello")],
      options: Map.merge(%{base_url: "https://api.example.test/v1"}, extra_options)
    }
  end

  defp authorization_headers(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> String.downcase(name) == "authorization" end)
    |> Enum.map(fn {_name, value} -> value end)
  end

  defp text_body do
    %{
      "id" => "chatcmpl_auth_text",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => "authenticated hello"},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
    }
  end
end
