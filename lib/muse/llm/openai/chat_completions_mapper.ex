defmodule Muse.LLM.OpenAI.ChatCompletionsMapper do
  @moduledoc """
  Maps a `Muse.LLM.Request` to an OpenAI Chat Completions JSON payload.

  Produces a JSON-compatible map with only string keys (no debug atom keys),
  suitable for `Jason.encode!/1`. No HTTP client or network dependency.

  ## Usage

      iex> request = %Muse.LLM.Request{model: "gpt-4.1", messages: [Muse.LLM.Message.user("hello")]}
      iex> payload = Muse.LLM.OpenAI.ChatCompletionsMapper.to_payload(request)
      iex> payload["model"]
      "gpt-4.1"
      iex> Jason.encode!(payload) |> Jason.decode!() |> Map.get("model")
      "gpt-4.1"

  """

  alias Muse.EventPayloadRedactor
  alias Muse.LLM.{Message, Request}

  @doc """
  Returns the OpenAI Chat Completions API endpoint path.
  """
  @spec endpoint_path() :: String.t()
  def endpoint_path, do: "/chat/completions"

  @doc """
  Converts a `Muse.LLM.Request` into an OpenAI Chat Completions request payload.

  Returns a map with only JSON-compatible (string) keys, ready for
  `Jason.encode!/1`. Optional fields (`temperature`, `max_tokens`,
  `response_format`, `name`) are included only when non-nil.

  ## Tool handling

  Tool specs produced by `Muse.Tool.Spec.to_provider_schema/1` include an
  atom `:name` key for debug-preview compatibility. This mapper strips
  that key to produce a clean JSON payload.

  When tools are present and `tool_choice` is `nil`, it defaults to `"auto"`.
  """
  @spec to_payload(Request.t()) :: map()
  def to_payload(%Request{} = request) do
    base = %{
      "model" => request.model,
      "messages" => map_messages(request.messages)
    }

    base
    |> maybe_put_tools(request.tools)
    |> maybe_put_tool_choice(request.tools, request.tool_choice)
    |> maybe_put("stream", request.stream)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("max_tokens", request.max_tokens)
    |> maybe_put_response_format(request.response_format)
  end

  # ---------------------------------------------------------------------------
  # response_format translation
  # ---------------------------------------------------------------------------

  # Omit when nil.
  defp maybe_put_response_format(payload, nil), do: payload

  # Already in OpenAI-compatible shape (json_schema, json_object, text) —
  # pass through with json_value conversion for key normalization.
  defp maybe_put_response_format(payload, %{type: type} = rf)
       when type in ["json_schema", "json_object", "text"] do
    Map.put(payload, "response_format", json_value(rf))
  end

  defp maybe_put_response_format(payload, %{"type" => type} = rf)
       when type in ["json_schema", "json_object", "text"] do
    Map.put(payload, "response_format", json_value(rf))
  end

  # Raw JSON Schema (type: "object") — wrap into OpenAI json_schema format.
  #
  # OpenAI's Chat Completions API does NOT accept a bare JSON Schema as
  # `response_format`.  It requires one of:
  #   {type: "text"}               — default text output
  #   {type: "json_object"}        — valid JSON, no schema enforcement
  #   {type: "json_schema", json_schema: {name, schema, strict}} — Structured Outputs
  #
  # When ModelPreparer attaches Muse.PlanSchema.schema() (a raw JSON Schema
  # with atom keys), the mapper must wrap it into the `json_schema` envelope.
  #
  # We use `strict: true` with a strict-compatible transformation of the
  # schema: all object nodes get `additionalProperties: false` and all
  # properties become required. This satisfies OpenAI's Structured Outputs
  # constraints while preserving the schema's semantic structure.
  defp maybe_put_response_format(payload, %{type: "object"} = raw_schema) do
    strict_schema = make_schema_strict_compatible(raw_schema)

    wrapped = %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "response",
        "schema" => strict_schema,
        "strict" => true
      }
    }

    Map.put(payload, "response_format", wrapped)
  end

  defp maybe_put_response_format(payload, %{"type" => "object"} = raw_schema) do
    strict_schema = make_schema_strict_compatible(raw_schema)

    wrapped = %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "response",
        "schema" => strict_schema,
        "strict" => true
      }
    }

    Map.put(payload, "response_format", wrapped)
  end

  # Fallback: any other response_format shape (e.g. atom-key map with
  # unknown structure) — convert with json_value for safe serialization.
  defp maybe_put_response_format(payload, rf) do
    Map.put(payload, "response_format", json_value(rf))
  end

  # ---------------------------------------------------------------------------
  # Strict-compatible JSON Schema transformation
  # ---------------------------------------------------------------------------

  # Recursively transform a JSON Schema so it satisfies OpenAI's Structured
  # Outputs constraints for `strict: true`:
  #
  #   1. Every `{type: "object"}` must have `additionalProperties: false`.
  #   2. Every `{type: "object"}` must list *all* properties in `required`.
  #   3. No `$ref` outside of `$defs` (our schemas don't use $ref).
  #
  # The function also normalizes atom keys to string keys for JSON safety.
  #
  # After this transformation, the model is guaranteed to produce output
  # conforming to the schema. Optional fields will always be present (with
  # default values like empty arrays/strings), and PlanSchema.validate/1
  # normalization handles defaults gracefully.

  @spec make_schema_strict_compatible(map()) :: map()
  # Object with atom-key properties
  defp make_schema_strict_compatible(%{type: "object", properties: properties} = schema)
       when is_map(properties) do
    transformed =
      Map.new(properties, fn {k, v} ->
        {json_key(k), make_schema_strict_compatible(v)}
      end)

    all_required = Map.keys(transformed) |> Enum.sort()

    base = %{
      "type" => "object",
      "properties" => transformed,
      "required" => all_required,
      "additionalProperties" => false
    }

    # Carry over description if present
    schema
    |> Map.take([:description, "description"])
    |> Enum.reduce(base, fn
      {:description, v}, acc -> Map.put(acc, "description", v)
      {"description", v}, acc -> Map.put(acc, "description", v)
      _, acc -> acc
    end)
  end

  # Object with string-key properties (already JSON-ready)
  defp make_schema_strict_compatible(%{"type" => "object", "properties" => properties} = schema)
       when is_map(properties) do
    transformed =
      Map.new(properties, fn {k, v} ->
        {json_key(k), make_schema_strict_compatible(v)}
      end)

    all_required = Map.keys(transformed) |> Enum.sort()

    base = %{
      "type" => "object",
      "properties" => transformed,
      "required" => all_required,
      "additionalProperties" => false
    }

    schema
    |> Map.take(["description"])
    |> Enum.reduce(base, fn
      {"description", v}, acc -> Map.put(acc, "description", v)
      _, acc -> acc
    end)
  end

  # Bare object without explicit properties (e.g. alternatives.items: %{type: "object"})
  # OpenAI strict mode requires properties + additionalProperties: false on all objects
  defp make_schema_strict_compatible(%{type: "object"} = _schema) do
    %{"type" => "object", "properties" => %{}, "required" => [], "additionalProperties" => false}
  end

  defp make_schema_strict_compatible(%{"type" => "object"} = _schema) do
    %{"type" => "object", "properties" => %{}, "required" => [], "additionalProperties" => false}
  end

  # Object with additionalProperties: true — must be overridden to false for strict mode
  # (e.g. metadata: %{type: "object", additionalProperties: true})
  # This clause runs after the property-based clauses, so it only matches bare objects
  # or objects that explicitly set additionalProperties but have no declared properties.
  defp make_schema_strict_compatible(%{type: "object", additionalProperties: _} = schema) do
    properties =
      case Map.get(schema, :properties) || Map.get(schema, "properties") do
        nil -> %{}
        props -> Map.new(props, fn {k, v} -> {json_key(k), make_schema_strict_compatible(v)} end)
      end

    all_required = Map.keys(properties) |> Enum.sort()

    %{
      "type" => "object",
      "properties" => properties,
      "required" => all_required,
      "additionalProperties" => false
    }
  end

  defp make_schema_strict_compatible(%{"type" => "object", "additionalProperties" => _} = schema) do
    properties =
      case Map.get(schema, "properties") do
        nil -> %{}
        props -> Map.new(props, fn {k, v} -> {json_key(k), make_schema_strict_compatible(v)} end)
      end

    all_required = Map.keys(properties) |> Enum.sort()

    %{
      "type" => "object",
      "properties" => properties,
      "required" => all_required,
      "additionalProperties" => false
    }
  end

  # Array with atom-key items — recursively transform the items schema
  defp make_schema_strict_compatible(%{type: "array", items: items} = schema)
       when is_map(items) do
    base = %{"type" => "array", "items" => make_schema_strict_compatible(items)}

    # Carry over array constraints like minItems; strip incompatible keys like default
    schema
    |> Map.take([:minItems, "minItems"])
    |> Enum.reduce(base, fn
      {:minItems, v}, acc when is_integer(v) -> Map.put(acc, "minItems", v)
      {"minItems", v}, acc when is_integer(v) -> Map.put(acc, "minItems", v)
      _, acc -> acc
    end)
  end

  # Array with string keys
  defp make_schema_strict_compatible(%{"type" => "array", "items" => items} = schema)
       when is_map(items) do
    base = %{"type" => "array", "items" => make_schema_strict_compatible(items)}

    schema
    |> Map.take(["minItems"])
    |> Enum.reduce(base, fn
      {"minItems", v}, acc when is_integer(v) -> Map.put(acc, "minItems", v)
      _, acc -> acc
    end)
  end

  # Leaf types (string, number, boolean, etc.) — normalize to JSON-safe values.
  # Strip keys not supported by OpenAI Structured Outputs strict mode (e.g. "default").
  defp make_schema_strict_compatible(other) do
    other
    |> json_value()
    |> strip_strict_incompatible_keys()
  end

  # OpenAI Structured Outputs with strict: true does not support the "default" key
  # on properties. Strip it to avoid 400 errors.
  @strict_incompatible_keys ["default"]

  defp strip_strict_incompatible_keys(schema) when is_map(schema) do
    Map.drop(schema, @strict_incompatible_keys)
  end

  defp strip_strict_incompatible_keys(value), do: value

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  defp map_messages(nil), do: []

  defp map_messages(messages) when is_list(messages) do
    Enum.map(messages, &map_message/1)
  end

  defp map_message(%Message{} = msg) do
    base = %{
      "role" => Atom.to_string(msg.role),
      "content" => msg.content
    }

    base
    |> maybe_put("name", msg.name)
    |> maybe_put("tool_call_id", msg.tool_call_id)
  end

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  defp maybe_put_tools(payload, nil), do: payload
  defp maybe_put_tools(payload, []), do: payload

  defp maybe_put_tools(payload, tools) when is_list(tools) do
    Map.put(payload, "tools", Enum.map(tools, &map_tool/1))
  end

  defp map_tool(tool) when is_map(tool) do
    # Strip debug atom keys (e.g. :name) from tool specs produced by
    # Muse.Tool.Spec.to_provider_schema/1, redact secret-like strings in tool
    # schema/debug data, and convert nested keys to provider-ready JSON strings.
    tool
    |> Map.drop([:name])
    |> EventPayloadRedactor.redact()
    |> json_value()
    |> provider_ready_tool()
  end

  defp provider_ready_tool(%{"type" => "function", "function" => function})
       when is_map(function) do
    %{
      "type" => "function",
      "function" => provider_ready_function(function)
    }
  end

  defp provider_ready_tool(tool), do: tool

  defp provider_ready_function(function) do
    function
    |> Map.take(["name", "description", "parameters", "strict"])
  end

  # ---------------------------------------------------------------------------
  # Tool choice
  # ---------------------------------------------------------------------------

  defp maybe_put_tool_choice(payload, nil, _tool_choice), do: payload
  defp maybe_put_tool_choice(payload, [], _tool_choice), do: payload
  defp maybe_put_tool_choice(payload, _tools, nil), do: Map.put(payload, "tool_choice", "auto")

  defp maybe_put_tool_choice(payload, _tools, :auto),
    do: Map.put(payload, "tool_choice", "auto")

  defp maybe_put_tool_choice(payload, _tools, :none),
    do: Map.put(payload, "tool_choice", "none")

  defp maybe_put_tool_choice(payload, _tools, :required),
    do: Map.put(payload, "tool_choice", "required")

  defp maybe_put_tool_choice(payload, _tools, {:function, name}) when is_binary(name) do
    Map.put(payload, "tool_choice", %{
      "type" => "function",
      "function" => %{"name" => name}
    })
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, json_value(value))

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
end
