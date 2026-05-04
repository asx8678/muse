defmodule Muse.LLM.OpenAI.RequestMapperContractTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{Message, Request}
  alias Muse.LLM.OpenAI.{ChatCompletionsMapper, ResponsesMapper}
  alias Muse.Tool.Spec

  @fake_api_key "sk-test-secret"
  @fake_bearer "Bearer secret"

  describe "OpenAI request mapper wire contract" do
    test "both mapper payloads are Jason-encodable and contain no atom keys" do
      request = contract_request()

      for {wire_api, payload} <- mapped_payloads(request) do
        assert is_binary(Jason.encode!(payload))
        assert_no_atom_keys!(payload, [wire_api])
      end
    end

    test "metadata/options stay provider-internal and sensitive tool values are not emitted raw" do
      request = secret_boundary_request()

      for {wire_api, payload} <- mapped_payloads(request) do
        refute Map.has_key?(payload, "metadata"),
               "#{wire_api} emitted request metadata into the wire payload"

        refute Map.has_key?(payload, "options"),
               "#{wire_api} emitted request options into the wire payload"

        assert_no_raw_secret!(payload, @fake_api_key, wire_api)
        assert_no_raw_secret!(payload, @fake_bearer, wire_api)
      end
    end

    test "Tool.Spec provider schemas have their debug atom name stripped in both payload types" do
      schema = provider_schema_tool()
      assert schema[:name] == "workspace_lookup"

      request = %Request{
        model: "gpt-4.1-mini",
        messages: [Message.user("Use the workspace lookup tool.")],
        tools: [schema],
        tool_choice: {:function, "workspace_lookup"}
      }

      for {wire_api, payload} <- mapped_payloads(request) do
        assert_no_atom_keys!(payload, [wire_api])
        refute atom_key_present?(payload, :name)
        assert_provider_tool_name!(wire_api, payload, "workspace_lookup")
      end
    end
  end

  defp mapped_payloads(%Request{} = request) do
    [
      chat_completions: ChatCompletionsMapper.to_payload(request),
      responses: ResponsesMapper.to_payload(request)
    ]
  end

  defp contract_request do
    %Request{
      model: "gpt-4.1-mini",
      messages: [
        Message.system("Use provider-ready JSON payloads."),
        Message.user("Prepare a short workspace lookup plan."),
        Message.assistant("I will inspect the available tool schema first.")
      ],
      tools: [provider_schema_tool()],
      tool_choice: {:function, "workspace_lookup"},
      previous_response_id: "resp_contract_previous",
      stream: false,
      store: true,
      temperature: 0.2,
      max_tokens: 256,
      response_format: response_format()
    }
  end

  defp secret_boundary_request do
    %Request{
      model: "gpt-4.1-mini",
      messages: [
        Message.system("Keep provider debug payloads safe."),
        Message.user("Use the workspace lookup tool without leaking internal config.")
      ],
      tools: [secret_laced_provider_schema_tool()],
      metadata: %{
        api_key: @fake_api_key,
        authorization: @fake_bearer,
        safe_trace_id: "trace-contract"
      },
      options: %{
        headers: %{"Authorization" => @fake_bearer},
        api_key: @fake_api_key,
        retries: 0
      },
      stream: true,
      temperature: 0.0,
      max_tokens: 128
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
          glob: %{
            "type" => "string",
            "description" => "Optional glob filter"
          }
        },
        required: ["path"],
        additionalProperties: false
      }
    )
    |> Spec.to_provider_schema()
  end

  defp secret_laced_provider_schema_tool do
    tool = provider_schema_tool()

    parameters =
      tool["function"]["parameters"]
      |> put_in([:properties, :credential_hint], %{
        type: "string",
        description: "Never place #{@fake_api_key} or #{@fake_bearer} in tool schemas"
      })
      |> Map.put(:debug_default, @fake_api_key)

    function =
      tool["function"]
      |> Map.put("description", "Lookup workspace files; internal auth sample #{@fake_bearer}")
      |> Map.put("parameters", parameters)
      |> Map.put(:debug_authorization, @fake_bearer)

    tool
    |> Map.put("function", function)
    |> Map.put(:debug_api_key, @fake_api_key)
  end

  defp response_format do
    %{
      type: "json_schema",
      json_schema: %{
        name: "mapper_contract",
        strict: true,
        schema: %{
          type: "object",
          properties: %{
            summary: %{type: "string"}
          },
          required: ["summary"],
          additionalProperties: false
        }
      }
    }
  end

  defp assert_provider_tool_name!(:chat_completions, payload, expected_name) do
    assert [%{"function" => %{"name" => ^expected_name}}] = payload["tools"]
  end

  defp assert_provider_tool_name!(:responses, payload, expected_name) do
    assert [%{"name" => ^expected_name}] = payload["tools"]
  end

  defp assert_no_atom_keys!(value, path) when is_map(value) do
    Enum.each(value, fn {key, nested_value} ->
      refute is_atom(key),
             "expected no atom keys at #{format_path(path)}, got #{inspect(key)} in #{inspect(value)}"

      assert_no_atom_keys!(nested_value, path ++ [key])
    end)
  end

  defp assert_no_atom_keys!(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.each(fn {nested_value, index} ->
      assert_no_atom_keys!(nested_value, path ++ [index])
    end)
  end

  defp assert_no_atom_keys!(_value, _path), do: :ok

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

  defp assert_no_raw_secret!(payload, secret, wire_api) do
    encoded = Jason.encode!(payload)
    inspected = inspect(payload, limit: :infinity, printable_limit: :infinity)

    refute encoded =~ secret, "#{wire_api} leaked #{inspect(secret)} in encoded JSON: #{encoded}"

    refute inspected =~ secret,
           "#{wire_api} leaked #{inspect(secret)} in payload term: #{inspected}"
  end

  defp format_path(path) do
    path
    |> Enum.map(&to_string/1)
    |> Enum.join(".")
  end
end
