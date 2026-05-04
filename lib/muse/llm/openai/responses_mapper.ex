defmodule Muse.LLM.OpenAI.ResponsesMapper do
  @moduledoc """
  Maps provider-neutral `Muse.LLM.Request` structs to OpenAI Responses API
  request payloads.

  This module is deliberately pure: it builds JSON-compatible Elixir maps only.
  It does not know about HTTP clients, auth, retries, headers, or streaming
  parsers. Those belong in provider/transport modules. Tiny mapper, tiny drama.

  ## Mapping choices

    * `endpoint_path/0` returns `"/responses"` for callers that need the path.
    * System messages are joined with blank lines into `"instructions"` instead
      of being repeated in `"input"`.
    * User and assistant text history is emitted as Responses `"message"` input
      items with typed `"input_text"` content. The mapper intentionally uses the
      same text content shape for assistant history so downstream code gets one
      simple, JSON-safe representation.
    * Tool-result messages are emitted as `"function_call_output"` input items
      and also retain `"role"`, `"content"`, and `"tool_call_id"` so Muse can
      round-trip existing neutral message data without losing context.
    * `request.response_format` is mapped to Responses structured-output shape:
      `"text" => %{"format" => ...}`. The Chat Completions-only
      `"response_format"` key is not emitted here.
    * Provider/debug-only data such as `metadata`, `options`, `prompt_bundle`,
      and top-level tool debug atom keys are not included.

  The returned payload contains only maps with string keys and scalar/list/map
  values suitable for `Jason.encode!/1`.
  """

  alias Muse.EventPayloadRedactor
  alias Muse.LLM.{Message, Request}
  alias Muse.Tool.Spec

  @type json_scalar :: String.t() | number() | boolean() | nil
  @type json_value :: json_scalar() | [json_value()] | %{String.t() => json_value()}

  @doc """
  OpenAI Responses API endpoint path relative to an OpenAI-compatible base URL.
  """
  @spec endpoint_path() :: String.t()
  def endpoint_path, do: "/responses"

  @doc """
  Convert a provider-neutral LLM request into a JSON-compatible Responses API
  payload.
  """
  @spec to_payload(Request.t()) :: map()
  def to_payload(%Request{} = request) do
    messages = request.messages || []

    %{
      "model" => json_value(request.model),
      "input" => input_items(messages),
      "stream" => stream_value(request.stream),
      "store" => store_value(request.store)
    }
    |> maybe_put("instructions", system_instructions(messages))
    |> maybe_put_list("tools", tool_items(request.tools))
    |> maybe_put("tool_choice", tool_choice_value(request.tool_choice))
    |> maybe_put("previous_response_id", request.previous_response_id)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("max_output_tokens", request.max_tokens)
    |> maybe_put_response_format(request.response_format)
  end

  # -- Messages ----------------------------------------------------------------

  defp system_instructions(messages) when is_list(messages) do
    messages
    |> Enum.filter(&(role_string(&1) == "system"))
    |> Enum.map(&field(&1, :content))
    |> Enum.map(&text_value/1)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp input_items(messages) when is_list(messages) do
    messages
    |> Enum.reject(&(role_string(&1) == "system"))
    |> Enum.map(&message_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp message_item(message) do
    case role_string(message) do
      nil -> nil
      "tool" -> tool_result_item(message)
      role -> text_message_item(role, message)
    end
  end

  defp text_message_item(role, message) do
    %{
      "type" => "message",
      "role" => role,
      "content" => text_content(field(message, :content))
    }
    |> maybe_put("name", field(message, :name))
  end

  defp tool_result_item(message) do
    content = text_value(field(message, :content)) || ""
    tool_call_id = field(message, :tool_call_id)

    %{
      "type" => "function_call_output",
      "role" => "tool",
      "content" => content,
      "tool_call_id" => json_value(tool_call_id),
      "call_id" => json_value(tool_call_id),
      "output" => content
    }
    |> maybe_put("name", field(message, :name))
  end

  defp text_content(nil), do: []

  defp text_content(content) do
    [%{"type" => "input_text", "text" => text_value(content)}]
  end

  # -- Tools -------------------------------------------------------------------

  defp tool_items(nil), do: []

  defp tool_items(tools) when is_list(tools) do
    tools
    |> Enum.map(&tool_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp tool_items(_other), do: []

  defp tool_item(%Spec{} = spec) do
    function_tool(spec.name, spec.description, spec.input_schema)
  end

  defp tool_item(tool) when is_map(tool) do
    function = field(tool, :function)

    name = first_present([field(function, :name), field(tool, :name)])
    description = first_present([field(function, :description), field(tool, :description), ""])

    parameters =
      first_present([
        field(function, :parameters),
        field(tool, :parameters),
        field(tool, :input_schema),
        %{}
      ])

    if blank?(text_value(name)) do
      nil
    else
      function_tool(name, description, parameters)
    end
  end

  defp tool_item(_other), do: nil

  defp function_tool(name, description, parameters) do
    %{
      "type" => "function",
      "name" => redact_text(text_value(name)),
      "description" => redact_text(text_value(description) || ""),
      "parameters" =>
        (parameters || %{})
        |> EventPayloadRedactor.redact()
        |> json_value()
    }
  end

  # -- Optional request fields --------------------------------------------------

  defp tool_choice_value(nil), do: nil
  defp tool_choice_value(:auto), do: "auto"
  defp tool_choice_value(:none), do: "none"
  defp tool_choice_value(:required), do: "required"

  defp tool_choice_value({:function, name}),
    do: %{"type" => "function", "name" => text_value(name)}

  defp tool_choice_value(value) when is_binary(value), do: value
  defp tool_choice_value(value), do: json_value(value)

  defp maybe_put_response_format(payload, nil), do: payload

  defp maybe_put_response_format(payload, response_format) do
    Map.put(payload, "text", %{"format" => json_value(response_format)})
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, _key, ""), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, json_value(value))

  defp maybe_put_list(payload, _key, []), do: payload
  defp maybe_put_list(payload, key, values), do: Map.put(payload, key, json_value(values))

  defp stream_value(value) when is_boolean(value), do: value
  defp stream_value(_value), do: true

  defp store_value(value) when is_boolean(value), do: value
  defp store_value(_value), do: false

  # -- Generic JSON safety ------------------------------------------------------

  defp json_value(value)
       when is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value) do
    value
  end

  defp json_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(%Time{} = value), do: Time.to_iso8601(value)

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(%{__struct__: _struct} = value) do
    value
    |> Map.from_struct()
    |> json_value()
  end

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {json_key(key), json_value(nested_value)} end)
  end

  defp json_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> json_value()
  end

  defp json_value(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_number(key), do: to_string(key)
  defp json_key(key), do: inspect(key, limit: :infinity, printable_limit: :infinity)

  # -- Field/text helpers -------------------------------------------------------

  defp role_string(message) do
    message
    |> field(:role)
    |> case do
      nil -> nil
      role when is_binary(role) -> role
      role when is_atom(role) -> Atom.to_string(role)
      role -> text_value(role)
    end
  end

  defp field(nil, _key), do: nil

  defp field(%Message{} = message, key), do: Map.get(message, key)

  defp field(%{} = map, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end

  defp field(_other, _key), do: nil

  defp first_present(values) do
    Enum.find(values, &(not is_nil(&1) and &1 != ""))
  end

  defp text_value(nil), do: nil
  defp text_value(value) when is_binary(value), do: value
  defp text_value(value) when is_atom(value), do: Atom.to_string(value)
  defp text_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text_value(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp redact_text(nil), do: nil
  defp redact_text(value) when is_binary(value), do: EventPayloadRedactor.redact_string(value)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
