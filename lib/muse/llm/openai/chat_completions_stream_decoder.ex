defmodule Muse.LLM.OpenAI.ChatCompletionsStreamDecoder do
  @moduledoc """
  Decodes OpenAI Chat Completions streaming SSE chunks into canonical Muse events.

  Each streaming chunk contains a `choices[0].delta` object (instead of the
  full `message` found in non-streaming responses). This decoder accumulates
  deltas incrementally and emits `Muse.LLM.Event` structs:

    * `choices[0].delta.content`           → `:assistant_delta`
    * `choices[0].delta.tool_calls[i]`     → `:tool_call_started` (first delta for index),
                                              `:tool_call_delta` (subsequent deltas)
    * `choices[0].finish_reason` present    → `:assistant_completed`, `:tool_call_completed`
    * stream end (or final chunk with usage) → `:response_completed`

  ## Accumulator

  The decoder is stateful: `new/0` creates an accumulator, `decode_chunk/2`
  processes a decoded JSON map and returns `{events, acc}`, and `finalize/1`
  flushes any remaining state into the final `{events, response}` pair.

  ## Tool call streaming

  OpenAI streams tool calls incrementally:

    1. First delta: `%{index: 0, id: "call_abc", type: "function", function: %{name: "read_file", arguments: ""}}`
    2. Subsequent:  `%{index: 0, function: %{arguments: "{\"path\":"}}}`
    3. More:        `%{index: 0, function: %{arguments: "\"lib/muse.ex\"}"}}`

  The decoder concatenates argument fragments per tool-call index and emits
  complete tool calls at finalization.
  """

  alias Muse.LLM.{Event, Response, ToolCall}

  @type acc :: %{
          content_parts: [String.t()],
          tool_calls: %{non_neg_integer() => tool_call_acc()},
          finish_reason: String.t() | nil,
          id: String.t() | nil,
          usage: map() | nil,
          model: String.t() | nil,
          started: boolean()
        }

  @type tool_call_acc :: %{
          id: String.t() | nil,
          name: String.t() | nil,
          argument_fragments: [String.t()],
          raw_parts: [map()]
        }

  @doc """
  Create a new stream decoder accumulator.
  """
  @spec new() :: acc()
  def new do
    %{
      content_parts: [],
      tool_calls: %{},
      finish_reason: nil,
      id: nil,
      usage: nil,
      model: nil,
      started: false
    }
  end

  @doc """
  Decode a single streaming chunk (already decoded from JSON).

  Returns `{events, acc}` where `events` is a list of canonical `Muse.LLM.Event`
  structs to emit and `acc` is the updated accumulator.

  A chunk that cannot be decoded produces a `:provider_error` event but does
  not halt — the caller decides whether to continue.
  """
  @spec decode_chunk(map(), acc()) :: {[Event.t()], acc()}
  def decode_chunk(chunk, acc) when is_map(chunk) do
    events = []

    # Mark response as started on first chunk
    {events, acc} =
      if not acc.started do
        {[Event.response_started()], %{acc | started: true}}
      else
        {events, acc}
      end

    # Extract common fields
    acc =
      acc
      |> maybe_set_id(chunk)
      |> maybe_set_model(chunk)
      |> maybe_set_usage(chunk)

    # Process choices[0]
    case get_choice(chunk) do
      {:ok, choice} ->
        {choice_events, acc} = process_choice(choice, acc)
        {events ++ choice_events, acc}

      :no_choice ->
        # Chunks without choices (e.g. usage-only chunks at end of stream)
        {events, acc}
    end
  end

  @doc """
  Finalize the decoder, emitting completion events and building the response.

  Returns `{events, response}` where `events` are the final completion events
  and `response` is the assembled `%Muse.LLM.Response{}`.
  """
  @spec finalize(acc()) :: {[Event.t()], Response.t()}
  def finalize(acc) do
    events = []

    # Emit assistant_completed if we have content
    full_text = acc.content_parts |> Enum.reverse() |> Enum.join("")

    {events, full_text} =
      if full_text != "" do
        {events ++ [Event.assistant_completed(full_text)], full_text}
      else
        {events, nil}
      end

    # Finalize tool calls
    completed_tool_calls = finalize_tool_calls(acc.tool_calls)

    {events, completed_tool_calls} =
      if completed_tool_calls != [] do
        tool_events =
          completed_tool_calls
          |> Enum.map(fn tc -> Event.tool_call_completed(tc) end)

        {events ++ tool_events, completed_tool_calls}
      else
        {events, []}
      end

    # Determine finish_reason
    finish_reason = acc.finish_reason || default_finish_reason(full_text, completed_tool_calls)

    # Build usage (prefer accumulated usage, normalize atom keys)
    usage = normalize_usage(acc.usage)

    # Emit response_completed
    events = events ++ [Event.response_completed(usage)]

    response =
      Response.new(
        id: acc.id,
        content: full_text,
        text: full_text,
        tool_calls: completed_tool_calls,
        usage: usage,
        finish_reason: finish_reason
      )

    {events, response}
  end

  # ---------------------------------------------------------------------------
  # Chunk processing
  # ---------------------------------------------------------------------------

  defp get_choice(chunk) do
    case fetch(chunk, "choices") do
      {:ok, [choice | _]} when is_map(choice) -> {:ok, choice}
      _ -> :no_choice
    end
  end

  defp maybe_set_id(acc, chunk) do
    case fetch(chunk, "id") do
      {:ok, id} when is_binary(id) -> %{acc | id: id}
      _ -> acc
    end
  end

  defp maybe_set_model(acc, chunk) do
    case fetch(chunk, "model") do
      {:ok, model} when is_binary(model) -> %{acc | model: model}
      _ -> acc
    end
  end

  defp maybe_set_usage(acc, chunk) do
    case fetch(chunk, "usage") do
      {:ok, usage} when is_map(usage) -> %{acc | usage: usage}
      _ -> acc
    end
  end

  defp process_choice(choice, acc) do
    # Extract delta
    delta =
      case fetch(choice, "delta") do
        {:ok, delta} when is_map(delta) -> delta
        _ -> %{}
      end

    # Process content delta
    {content_events, acc} = process_content_delta(delta, acc)

    # Process tool call deltas
    {tool_events, acc} = process_tool_call_deltas(delta, acc)

    # Process finish_reason
    {finish_events, acc} = process_finish_reason(choice, acc)

    {content_events ++ tool_events ++ finish_events, acc}
  end

  defp process_content_delta(delta, acc) do
    case fetch(delta, "content") do
      {:ok, text} when is_binary(text) and text != "" ->
        {[Event.assistant_delta(text)], %{acc | content_parts: [text | acc.content_parts]}}

      _ ->
        {[], acc}
    end
  end

  defp process_tool_call_deltas(delta, acc) do
    case fetch(delta, "tool_calls") do
      {:ok, tool_call_deltas} when is_list(tool_call_deltas) ->
        Enum.reduce(tool_call_deltas, {[], acc}, fn tc_delta, {events, acc} ->
          process_single_tool_call_delta(tc_delta, events, acc)
        end)

      _ ->
        {[], acc}
    end
  end

  defp process_single_tool_call_delta(tc_delta, events, acc) when is_map(tc_delta) do
    index =
      case fetch(tc_delta, "index") do
        {:ok, idx} when is_integer(idx) -> idx
        _ -> 0
      end

    existing = Map.get(acc.tool_calls, index, new_tool_call_acc())

    # Extract fields from delta
    id =
      case fetch(tc_delta, "id") do
        {:ok, id} when is_binary(id) -> id
        _ -> existing.id
      end

    function =
      case fetch(tc_delta, "function") do
        {:ok, func} when is_map(func) -> func
        _ -> %{}
      end

    name =
      case fetch(function, "name") do
        {:ok, n} when is_binary(n) -> n
        _ -> existing.name
      end

    arg_fragment =
      case fetch(function, "arguments") do
        {:ok, args} when is_binary(args) -> args
        _ -> nil
      end

    updated = %{
      existing
      | id: id,
        name: name,
        argument_fragments: existing.argument_fragments ++ List.wrap(arg_fragment),
        raw_parts: existing.raw_parts ++ [tc_delta]
    }

    acc = %{acc | tool_calls: Map.put(acc.tool_calls, index, updated)}

    # Emit tool_call_started on first delta for this index
    {events, acc} =
      if existing.id == nil and existing.name == nil and (id != nil or name != nil) do
        # First delta for this tool call — emit started
        partial_tc = ToolCall.new(name || "", %{}, id: id)
        {events ++ [Event.tool_call_started(partial_tc)], acc}
      else
        # Subsequent delta — emit tool_call_delta
        partial_tc = ToolCall.new(name || existing.name || "", %{}, id: id || existing.id)
        {events ++ [Event.tool_call_delta(partial_tc)], acc}
      end

    {events, acc}
  end

  defp process_single_tool_call_delta(_tc_delta, events, acc), do: {events, acc}

  defp process_finish_reason(choice, acc) do
    case fetch(choice, "finish_reason") do
      {:ok, reason} when is_binary(reason) and reason != "" ->
        {[], %{acc | finish_reason: reason}}

      {:ok, nil} ->
        {[], acc}

      _ ->
        {[], acc}
    end
  end

  # ---------------------------------------------------------------------------
  # Finalization helpers
  # ---------------------------------------------------------------------------

  defp new_tool_call_acc do
    %{id: nil, name: nil, argument_fragments: [], raw_parts: []}
  end

  defp finalize_tool_calls(tool_calls) when tool_calls == %{}, do: []

  defp finalize_tool_calls(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {index, _acc} -> index end)
    |> Enum.map(fn {_index, acc} -> build_tool_call(acc) end)
    |> Enum.filter(&valid_tool_call?/1)
  end

  defp build_tool_call(acc) do
    arguments_json = Enum.join(acc.argument_fragments, "")
    arguments = decode_tool_arguments(arguments_json, acc.name || "unknown")

    ToolCall.new(
      acc.name || "",
      arguments,
      id: acc.id,
      raw: acc.raw_parts
    )
  end

  defp decode_tool_arguments("", _name), do: %{}

  defp decode_tool_arguments(json, _name) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, _decoded} -> %{}
      {:error, _reason} -> %{}
    end
  end

  defp valid_tool_call?(%ToolCall{name: name}) when is_binary(name) and name != "", do: true
  defp valid_tool_call?(_), do: false

  defp default_finish_reason(nil, []), do: "stop"
  defp default_finish_reason(nil, _tool_calls), do: "tool_calls"
  defp default_finish_reason(_text, _tool_calls), do: "stop"

  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) when is_map(usage) do
    %{}
    |> maybe_put_usage_key(usage, "prompt_tokens", :prompt_tokens)
    |> maybe_put_usage_key(usage, "completion_tokens", :completion_tokens)
    |> maybe_put_usage_key(usage, "total_tokens", :total_tokens)
  end

  defp normalize_usage(usage), do: usage

  defp maybe_put_usage_key(normalized, usage, string_key, atom_key) do
    cond do
      Map.has_key?(usage, string_key) ->
        Map.put(normalized, atom_key, Map.fetch!(usage, string_key))

      Map.has_key?(usage, atom_key) ->
        Map.put(normalized, atom_key, Map.fetch!(usage, atom_key))

      true ->
        normalized
    end
  end

  # ---------------------------------------------------------------------------
  # JSON helpers
  # ---------------------------------------------------------------------------

  @known_atom_keys %{
    "arguments" => :arguments,
    "choices" => :choices,
    "completion_tokens" => :completion_tokens,
    "content" => :content,
    "delta" => :delta,
    "finish_reason" => :finish_reason,
    "function" => :function,
    "id" => :id,
    "index" => :index,
    "message" => :message,
    "model" => :model,
    "name" => :name,
    "prompt_tokens" => :prompt_tokens,
    "role" => :role,
    "tool_calls" => :tool_calls,
    "total_tokens" => :total_tokens,
    "type" => :type,
    "usage" => :usage
  }

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    atom_key = Map.get(@known_atom_keys, key, key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, atom_key) -> {:ok, Map.fetch!(map, atom_key)}
      true -> :error
    end
  end
end
