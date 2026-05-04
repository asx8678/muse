defmodule Muse.LLM.OpenAICompatibleProviderContractTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request, Response, ToolCall}
  alias Muse.LLM.OpenAICompatibleProvider
  alias Muse.Tool.Spec

  @metadata_secret "sk-test-secret"
  @option_secret "Bearer secret"
  @user_api_key "sk-test-user-visible"
  @user_bearer "Bearer user-visible"

  describe "complete/2 provider contract" do
    test "posts provider-ready Chat Completions JSON through injected post_fn and decodes normalized response" do
      parent = self()
      provider_body = chat_completions_response_body()
      request = contract_request()

      post_fn = fn url, options ->
        send(parent, {:post_called, url, options})
        {:ok, Req.Response.new(status: 200, body: Jason.encode!(provider_body))}
      end

      assert {:ok, %Response{} = response} =
               OpenAICompatibleProvider.complete(request, post_fn: post_fn)

      assert_receive {:post_called, url, post_options}
      assert url == "http://127.0.0.1:9/openai-compatible/v1/chat/completions"

      posted_json = Keyword.fetch!(post_options, :json)
      assert is_binary(Jason.encode!(posted_json))
      assert_string_keys!(posted_json)

      assert posted_json["stream"] == false
      assert posted_json["model"] == "gpt-4.1-mini"
      refute Map.has_key?(posted_json, "metadata")
      refute Map.has_key?(posted_json, "options")

      assert [
               %{"role" => "system", "content" => "Use provider-ready JSON only."},
               %{"role" => "user", "content" => user_content}
             ] = posted_json["messages"]

      assert user_content == user_message_content()

      assert [tool] = posted_json["tools"]

      assert tool == %{
               "type" => "function",
               "function" => %{
                 "name" => "workspace_lookup",
                 "description" => "Lookup workspace files by path.",
                 "parameters" => %{
                   "type" => "object",
                   "properties" => %{
                     "path" => %{
                       "type" => "string",
                       "description" => "Workspace-relative path"
                     },
                     "limit" => %{
                       "type" => "integer",
                       "minimum" => 1
                     }
                   },
                   "required" => ["path"],
                   "additionalProperties" => false
                 }
               }
             }

      refute atom_key_present?(tool, :name)

      assert posted_json["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "workspace_lookup"}
             }

      assert response.id == "chatcmpl_contract"
      assert response.content == "The workspace lookup is ready."
      assert response.text == "The workspace lookup is ready."
      assert response.finish_reason == "tool_calls"
      assert response.usage == %{prompt_tokens: 13, completion_tokens: 8, total_tokens: 21}
      assert response.raw == provider_body

      assert [tool_call] = response.tool_calls
      assert %ToolCall{} = tool_call
      assert tool_call.id == "call_workspace_lookup"
      assert tool_call.name == "workspace_lookup"
      assert tool_call.arguments == %{"path" => "lib/muse.ex", "limit" => 1}

      assert tool_call.raw ==
               provider_body["choices"] |> hd() |> get_in(["message", "tool_calls"]) |> hd()
    end

    test "redaction boundary omits request metadata/options from outbound JSON and provider errors while preserving user content" do
      parent = self()
      request = contract_request()

      post_fn = fn url, options ->
        send(parent, {:post_called, url, options})

        {:ok,
         Req.Response.new(
           status: 429,
           body: %{"error" => %{"message" => "upstream rate limited the request"}}
         )}
      end

      assert {:error, error_reason} = OpenAICompatibleProvider.complete(request, post_fn: post_fn)
      assert {:provider_http_error, %{status: 429}} = error_reason

      assert_receive {:post_called, _url, post_options}
      posted_json = Keyword.fetch!(post_options, :json)
      encoded_json = Jason.encode!(posted_json)

      refute Map.has_key?(posted_json, "metadata")
      refute Map.has_key?(posted_json, "options")
      refute encoded_json =~ @metadata_secret
      refute encoded_json =~ @option_secret

      assert encoded_json =~ @user_api_key
      assert encoded_json =~ @user_bearer
      assert get_in(posted_json, ["messages", Access.at(1), "content"]) == user_message_content()

      inspected_error = inspect(error_reason, limit: :infinity, printable_limit: :infinity)

      refute inspected_error =~ "metadata"
      refute inspected_error =~ "options"
      refute inspected_error =~ @metadata_secret
      refute inspected_error =~ @option_secret
      refute inspected_error =~ @user_api_key
      refute inspected_error =~ @user_bearer
    end
  end

  defp contract_request do
    schema = provider_schema_tool()
    assert schema[:name] == "workspace_lookup"

    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :chat_completions,
      transport: :none,
      messages: [
        Message.system("Use provider-ready JSON only."),
        Message.user(user_message_content())
      ],
      tools: [schema],
      tool_choice: {:function, "workspace_lookup"},
      stream: true,
      metadata: %{
        api_key: @metadata_secret,
        authorization: @option_secret,
        trace_id: "trace-provider-contract"
      },
      options: %{
        base_url: "http://127.0.0.1:9/openai-compatible/v1/",
        headers: %{"Authorization" => @option_secret},
        api_key: @metadata_secret,
        debug_options: %{authorization: @option_secret},
        timeout_ms: 25,
        max_retries: 0
      }
    }
  end

  defp provider_schema_tool do
    Spec.new!(
      name: "workspace_lookup",
      description: "Lookup workspace files by path.",
      handler: __MODULE__.WorkspaceLookup,
      input_schema: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Workspace-relative path"
          },
          limit: %{
            type: "integer",
            minimum: 1
          }
        },
        required: ["path"],
        additionalProperties: false
      }
    )
    |> Spec.to_provider_schema()
  end

  defp chat_completions_response_body do
    %{
      "id" => "chatcmpl_contract",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "The workspace lookup is ready.",
            "tool_calls" => [
              %{
                "id" => "call_workspace_lookup",
                "type" => "function",
                "function" => %{
                  "name" => "workspace_lookup",
                  "arguments" => ~s({"path":"lib/muse.ex","limit":1})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 13, "completion_tokens" => 8, "total_tokens" => 21}
    }
  end

  defp user_message_content do
    "User content is payload data, not debug metadata: #{@user_api_key} and #{@user_bearer}."
  end

  defp assert_string_keys!(value, path \\ [])

  defp assert_string_keys!(value, path) when is_map(value) do
    Enum.each(value, fn {key, nested_value} ->
      assert is_binary(key),
             "expected string key at #{format_path(path)}, got #{inspect(key)} in #{inspect(value)}"

      assert_string_keys!(nested_value, path ++ [key])
    end)
  end

  defp assert_string_keys!(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.each(fn {nested_value, index} ->
      assert_string_keys!(nested_value, path ++ [index])
    end)
  end

  defp assert_string_keys!(_value, _path), do: :ok

  defp atom_key_present?(%{} = map, atom_key) when is_atom(atom_key) do
    Enum.any?(map, fn
      {^atom_key, _value} -> true
      {_key, nested_value} -> atom_key_present?(nested_value, atom_key)
    end)
  end

  defp atom_key_present?(list, atom_key) when is_list(list) do
    Enum.any?(list, &atom_key_present?(&1, atom_key))
  end

  defp atom_key_present?(_value, _atom_key), do: false

  defp format_path([]), do: "<root>"

  defp format_path(path) do
    path
    |> Enum.map(&to_string/1)
    |> Enum.join(".")
  end
end
