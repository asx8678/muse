defmodule Muse.LLM.OpenAI.ChatCompletionsStreamDecoder do
  @moduledoc """
  Decodes OpenAI Chat Completions SSE streaming chunks into Muse events.

  This module is intentionally pure: it accepts a list of parsed SSE events
  (from `Muse.LLM.Transport.SSE.Parser`) and returns a list of
  `Muse.LLM.Event.t()` structs, along with an accumulator for cross-chunk
  state (tool call assembly, usage tracking).

  ## Error handling

  Malformed JSON in a chunk produces a `{:provider_decode_error, ...}` result
  rather than a crash. The decoder accumulates all successfully parsed events
  before the failure and returns them alongside the error, so callers can
  emit partial deltas before the error event.

  ## `[DONE]` marker

  An SSE event with `data: "[DONE]"` signals stream completion. If no usage
  was received in prior chunks, the completion event carries `nil` usage.
  """

  alias Muse.EventPayloadRedactor
  alias Muse.LLM.{Event, ToolCall}

  @max_error_message_length 300

  @type accum :: %{
          text: String.t(),
          tool_calls: [map()],
          usage: map() | nil,
          id: String.t() | nil,
          finish_reason: String.t() | nil,
          had_done: boolean()
        }

  @doc """
  Decode a list of SSE events into Muse events and an accumulator.

  Returns `{events, accum}` where `events` is a list of `Muse.LLM.Event.t()`
  and `accum` carries cross-chunk state.

  On decode failure in any chunk, returns `{successful_events, {:error, reason}}`
  where `successful_events` contains all events parsed before the failure.
  """
  @spec decode([map()], accum()) :: {[Event.t()], accum()} | {[Event.t()], {:error, term()}}
  def decode(sse_events, accum \\ new_accum())

  def decode([], accum), do: {[], accum}

  def decode(sse_events, accum) do
    sse_events
    |> Enum.reduce_while({[], accum}, fn sse_event, {events, acc} ->
      case decode_one(sse_event, acc) do
        {:ok, new_events, new_acc} ->
          {:cont, {events ++ new_events, new_acc}}

        {:error, reason} ->
          {:halt, {events, {:error, reason}}}
      end
    end)
  end

  @doc """
  Create a fresh accumulator for stream decoding.
  """
  @spec new_accum() :: accum()
  def new_accum do
    %{text: "", tool_calls: [], usage: nil, id: nil, finish_reason: nil, had_done: false}
  end

  @doc """
  Finalize a stream: produce completion events from the accumulator.

  Emits `:assistant_completed` (if text was accumulated), and
  `:response_completed` with usage.
  """
  @spec finalize(accum()) :: {[Event.t()], accum()}
  def finalize(accum) do
    events = []

    events =
      if accum.text != "" do
        events ++ [Event.assistant_completed(accum.text)]
      else
        events
      end

    events = events ++ [Event.response_completed(accum.usage)]
    {events, %{accum | had_done: true}}
  end

  # ---------------------------------------------------------------------------
  # Single SSE event decoding
  # ---------------------------------------------------------------------------

  defp decode_one(%{data: "[DONE]"}, accum) do
    {final_events, final_accum} = finalize(accum)
    {:ok, final_events, %{final_accum | had_done: true}}
  end

  defp decode_one(%{data: data}, accum) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, body} when is_map(body) ->
        {:ok, events, new_accum} = decode_chunk_body(body, accum)
        {:ok, events, new_accum}

      {:ok, _not_a_map} ->
        {:error,
         {:provider_decode_error, redact_error("SSE chunk data did not decode to a JSON object")}}

      {:error, reason} ->
        msg = reason |> Exception.message() |> redact_error()
        {:error, {:provider_decode_error, msg}}
    end
  end

  defp decode_one(_sse_event, accum), do: {:ok, [], accum}

  # ---------------------------------------------------------------------------
  # Chunk body decoding
  # ---------------------------------------------------------------------------

  defp decode_chunk_body(body, accum) do
    # Extract id if present
    id =
      case Map.get(body, "id") do
        id when is_binary(id) -> id
        _ -> accum.id
      end

    choices = Map.get(body, "choices", [])
    usage = decode_usage_from_chunk(body, accum.usage)

    case choices do
      [choice | _] when is_map(choice) ->
        decode_choice(choice, %{accum | id: id, usage: usage})

      _ ->
        # No choices — possibly a usage-only chunk
        {:ok, [], %{accum | id: id, usage: usage}}
    end
  end

  defp decode_usage_from_chunk(body, current_usage) do
    case Map.get(body, "usage") do
      usage when is_map(usage) -> merge_usage(current_usage, usage)
      _ -> current_usage
    end
  end

  defp merge_usage(nil, new), do: normalize_usage(new)
  defp merge_usage(current, new), do: Map.merge(current, normalize_usage(new))

  defp normalize_usage(usage) do
    ~w(prompt_tokens completion_tokens total_tokens)a
    |> Enum.reduce(%{}, fn key, acc ->
      val = Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
      if val, do: Map.put(acc, key, val), else: acc
    end)
  end

  # ---------------------------------------------------------------------------
  # Choice decoding
  # ---------------------------------------------------------------------------

  defp decode_choice(choice, accum) do
    delta = Map.get(choice, "delta", %{})
    finish_reason = Map.get(choice, "finish_reason")

    accum = if finish_reason, do: %{accum | finish_reason: finish_reason}, else: accum

    # Text delta
    {text_events, accum} = decode_text_delta(delta, accum)

    # Tool call deltas
    {tool_events, accum} = decode_tool_call_deltas(delta, accum)

    {:ok, text_events ++ tool_events, accum}
  end

  defp decode_text_delta(delta, accum) do
    content = Map.get(delta, "content")

    cond do
      is_binary(content) and content != "" ->
        new_text = accum.text <> content
        {[Event.assistant_delta(content)], %{accum | text: new_text}}

      is_binary(content) ->
        # Empty string delta — ignore
        {[], accum}

      true ->
        {[], accum}
    end
  end

  defp decode_tool_call_deltas(delta, accum) do
    case Map.get(delta, "tool_calls") do
      nil ->
        {[], accum}

      tool_call_deltas when is_list(tool_call_deltas) ->
        Enum.reduce(tool_call_deltas, {[], accum}, fn tc_delta, {events, acc} ->
          decode_tool_call_delta(tc_delta, events, acc)
        end)

      _ ->
        # Ignore malformed tool_calls
        {[], accum}
    end
  end

  defp decode_tool_call_delta(tc_delta, events, accum) when is_map(tc_delta) do
    index = Map.get(tc_delta, "index", length(accum.tool_calls))

    # Ensure we have enough slots
    tool_calls = ensure_tool_call_slots(accum.tool_calls, index)

    existing =
      Enum.at(tool_calls, index) ||
        %{"id" => nil, "function" => %{"name" => "", "arguments" => ""}}

    # Merge id
    updated =
      case Map.get(tc_delta, "id") do
        id when is_binary(id) and id != "" -> Map.put(existing, "id", id)
        _ -> existing
      end

    # Merge function
    updated =
      case Map.get(tc_delta, "function") do
        func when is_map(func) ->
          existing_func = Map.get(updated, "function", %{})

          merged_func =
            existing_func
            |> maybe_merge_field(func, "name")
            |> maybe_merge_field(func, "arguments")

          Map.put(updated, "function", merged_func)

        _ ->
          updated
      end

    new_tool_calls = List.replace_at(tool_calls, index, updated)
    new_accum = %{accum | tool_calls: new_tool_calls}

    # Emit tool_call_started on first fragment for this index
    events =
      if Map.get(tc_delta, "id") != nil and Map.get(existing, "id") == nil do
        events ++ [Event.tool_call_started(%{index: index, name: nil})]
      else
        events
      end

    {events, new_accum}
  end

  defp decode_tool_call_delta(_tc_delta, events, accum), do: {events, accum}

  defp ensure_tool_call_slots(tool_calls, index) when index < length(tool_calls), do: tool_calls

  defp ensure_tool_call_slots(tool_calls, index) do
    extra = index - length(tool_calls) + 1
    tool_calls ++ List.duplicate(nil, extra)
  end

  defp maybe_merge_field(target, source, field) do
    case Map.get(source, field) do
      nil -> target
      value -> Map.put(target, field, Map.get(target, field, "") <> value)
    end
  end

  # ---------------------------------------------------------------------------
  # Build final response from accumulator
  # ---------------------------------------------------------------------------

  @doc """
  Build a `Muse.LLM.Response` from the accumulated stream state.
  """
  @spec build_response(accum()) :: Muse.LLM.Response.t()
  def build_response(accum) do
    tool_calls =
      accum.tool_calls
      |> Enum.filter(& &1)
      |> Enum.map(&build_tool_call/1)

    content =
      if accum.text == "" and tool_calls != [] do
        nil
      else
        if accum.text == "", do: nil, else: accum.text
      end

    Muse.LLM.Response.new(
      id: accum.id,
      content: content,
      text: content,
      tool_calls: tool_calls,
      usage: accum.usage,
      finish_reason: accum.finish_reason
    )
  end

  defp build_tool_call(%{"function" => %{"name" => name, "arguments" => args}} = raw)
       when is_binary(name) do
    arguments =
      case Jason.decode(args || "{}") do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> %{}
      end

    ToolCall.new(name, arguments, id: Map.get(raw, "id"), raw: raw)
  end

  defp build_tool_call(_raw), do: nil

  # ---------------------------------------------------------------------------
  # Error helpers
  # ---------------------------------------------------------------------------

  defp redact_error(message) when is_binary(message) do
    message
    |> EventPayloadRedactor.redact_string()
    |> String.slice(0, @max_error_message_length)
  end
end
