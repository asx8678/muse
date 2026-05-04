defmodule Muse.LLM.OpenAI.ChatCompletionsStreamDecoder do
  @moduledoc """
  Accumulates OpenAI-compatible Chat Completions SSE streaming chunks into
  canonical `Muse.LLM.Event` structs and a final `%Muse.LLM.Response{}`.

  This module is intentionally pure: it accepts one decoded JSON chunk map per
  call — typically the `data:` JSON payload from an SSE event — and returns
  zero or more events.  It does not perform HTTP, retries, logging, or
  telemetry.

  ## Usage

      iex> decoder = ChatCompletionsStreamDecoder.new()
      iex> chunk = %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
      iex> {decoder, events} = ChatCompletionsStreamDecoder.feed(decoder, chunk)
      iex> events
      [%Muse.LLM.Event{type: :assistant_delta, text: "Hello"}]

      iex> decoder = ChatCompletionsStreamDecoder.feed(decoder, :done) |> elem(0)
      iex> {response, events} = ChatCompletionsStreamDecoder.finalize(decoder)
      iex> response.content
      "Hello"
      iex> Enum.map(events, & &1.type)
      [:assistant_completed, :response_completed]

  ## Chunk shapes

  Each chunk should be a decoded map with string keys as produced by the
  OpenAI-compatible Chat Completions streaming API (`data: {...}`).  The
  decoder also accepts `:done` or `"[DONE]"` as a stream-termination signal.

  ## State

  The decoder maintains an opaque accumulator.  Callers should treat the
  state as opaque and pass it back on each `feed/2` call.

  ## Event emission rules

    * Text `choices[].delta.content` → `:assistant_delta` events.
    * Role-only or empty deltas do not emit events.
    * Tool-call deltas (by index) emit `:tool_call_started`,
      `:tool_call_delta`, and — on `finalize/1` — `:tool_call_completed`.
    * Unknown or irrelevant chunks do not crash — they are silently ignored.
    * `finalize/1` produces the final `:assistant_completed`,
      `:tool_call_completed`, and `:response_completed` events.
  """

  alias Muse.LLM.{Event, Response, ToolCall}

  @max_error_message_length 300

  @type t :: %__MODULE__{
          text_parts: [String.t()],
          tool_calls: %{integer() => tool_acc()},
          id: String.t() | nil,
          usage: map() | nil,
          finish_reason: String.t() | nil,
          finalized: boolean()
        }

  @typep tool_acc :: %{
           id: String.t() | nil,
           name: String.t() | nil,
           arguments_parts: [String.t()],
           started: boolean()
         }

  defstruct [:text_parts, :tool_calls, :id, :usage, :finish_reason, :finalized]

  @doc """
  Creates a new empty decoder state.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      text_parts: [],
      tool_calls: %{},
      id: nil,
      usage: nil,
      finish_reason: nil,
      finalized: false
    }
  end

  @doc """
  Feeds a decoded chunk into the decoder.

  Accepts either a decoded JSON map (from an SSE `data:` line), the atom
  `:done`, or the string `"[DONE]"` to signal the stream has ended.

  Returns `{state, events}` where `events` is a (possibly empty) list of
  `Muse.LLM.Event` structs in chronological order.

  ## Parameters

    * `state` — the current decoder state (opaque)
    * `chunk` — a decoded JSON map, the atom `:done`, or `"[DONE]"` string

  ## Examples

      iex> state = ChatCompletionsStreamDecoder.new()
      iex> chunk = %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}
      iex> {state, [event]} = ChatCompletionsStreamDecoder.feed(state, chunk)
      iex> event.type
      :assistant_delta
      iex> event.text
      "Hello"
  """
  @spec feed(t(), map() | :done | String.t()) :: {t(), [Event.t()]}
  def feed(state, chunk)

  def feed(%__MODULE__{finalized: true} = state, _chunk) do
    {state, []}
  end

  def feed(state, :done) do
    {%{state | finalized: true}, []}
  end

  def feed(state, "[DONE]") do
    {%{state | finalized: true}, []}
  end

  def feed(%__MODULE__{} = state, chunk) when is_map(chunk) do
    state = capture_metadata(state, chunk)

    case Map.get(chunk, "choices") do
      nil -> {state, []}
      choices when is_list(choices) -> process_choices(state, choices)
      _other -> {state, []}
    end
  end

  def feed(state, _unknown) do
    {state, []}
  end

  @doc """
  Finalizes the decoder, returning the assembled response and finalization
  events.

  Produces these events in order:

    1. `:assistant_completed` with the assembled text (always emitted)
    2. `:tool_call_completed` per accumulated tool call
    3. `:response_completed` with usage (if available)

  Malformed tool-call argument JSON at finalization is redacted — no raw
  secret-bearing data leaks through the error message.

  ## Parameters

    * `state` — the decoder state after feeding `:done` / `"[DONE]"`

  ## Returns

      {%Muse.LLM.Response{}, [Muse.LLM.Event.t()]}
  """
  @spec finalize(t()) :: {Response.t(), [Event.t()]}
  def finalize(%__MODULE__{} = state) do
    content = state.text_parts |> Enum.reverse() |> Enum.join()

    {tool_calls, final_tool_events} =
      state.tool_calls
      |> Enum.sort_by(fn {index, _acc} -> index end)
      |> Enum.map_reduce([], fn {_index, acc}, evts ->
        case finalize_tool_call(acc) do
          {:ok, tc} -> {tc, [Event.tool_call_completed(tc) | evts]}
          {:error, _error} -> {nil, evts}
        end
      end)

    valid_tool_calls = Enum.reject(tool_calls, &is_nil/1)

    finish_reason =
      state.finish_reason ||
        if valid_tool_calls != [], do: "tool_calls", else: "stop"

    response =
      Response.new(
        id: state.id,
        content: content,
        text: content,
        tool_calls: valid_tool_calls,
        usage: state.usage,
        finish_reason: finish_reason
      )

    final_events =
      [Event.assistant_completed(content)] ++
        Enum.reverse(final_tool_events) ++
        [Event.response_completed(state.usage)]

    {response, final_events}
  end

  # ---------------------------------------------------------------------------
  # Metadata capture
  # ---------------------------------------------------------------------------

  defp capture_metadata(state, chunk) do
    state
    |> maybe_capture_id(chunk)
    |> maybe_capture_usage(chunk)
  end

  defp maybe_capture_id(state, chunk) do
    case Map.get(chunk, "id") do
      id when is_binary(id) and not is_nil(state.id) -> state
      id when is_binary(id) -> %{state | id: id}
      _other -> state
    end
  end

  defp maybe_capture_usage(state, chunk) do
    case Map.get(chunk, "usage") do
      usage when is_map(usage) -> %{state | usage: normalize_usage(usage)}
      _other -> state
    end
  end

  # ---------------------------------------------------------------------------
  # Choices processing
  # ---------------------------------------------------------------------------

  defp process_choices(state, choices) do
    state = capture_finish_reason(state, choices)

    choices
    |> Enum.filter(&match?(%{"delta" => %{}}, &1))
    |> Enum.reduce({state, []}, fn choice, {st, events} ->
      process_delta(st, choice["delta"], events)
    end)
  end

  defp capture_finish_reason(state, choices) do
    finish_reason =
      Enum.find_value(choices, fn
        %{"finish_reason" => reason} when is_binary(reason) -> reason
        _other -> nil
      end)

    case finish_reason do
      nil -> state
      reason -> %{state | finish_reason: reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Delta processing
  # ---------------------------------------------------------------------------

  defp process_delta(state, delta, events_acc) do
    {state, events} = process_content_delta(state, delta, events_acc)
    process_tool_call_delta(state, delta, events)
  end

  defp process_content_delta(state, delta, events_acc) do
    case Map.get(delta, "content") do
      content when is_binary(content) and content != "" ->
        state = %{state | text_parts: [content | state.text_parts]}
        {state, events_acc ++ [Event.assistant_delta(content)]}

      _other ->
        {state, events_acc}
    end
  end

  defp process_tool_call_delta(state, delta, events_acc) do
    case Map.get(delta, "tool_calls") do
      tool_calls when is_list(tool_calls) and tool_calls != [] ->
        Enum.reduce(tool_calls, {state, events_acc}, fn tc, {st, evts} ->
          process_one_tool_call(st, tc, evts)
        end)

      _other ->
        {state, events_acc}
    end
  end

  # ---------------------------------------------------------------------------
  # Individual tool call delta
  # ---------------------------------------------------------------------------

  defp process_one_tool_call(state, tc, events_acc) do
    index = Map.get(tc, "index", 0)

    acc = Map.get(state.tool_calls, index, new_tool_acc())
    {acc, new_events} = update_tool_acc(acc, tc, events_acc)

    state = %{state | tool_calls: Map.put(state.tool_calls, index, mark_started(acc))}
    {state, new_events}
  end

  defp new_tool_acc do
    %{
      id: nil,
      name: nil,
      arguments_parts: [],
      started: false
    }
  end

  defp mark_started(acc) do
    %{acc | started: true}
  end

  defp update_tool_acc(acc, tc, events_acc) do
    acc = maybe_set_tool_id(acc, tc)
    acc = maybe_set_tool_name(acc, tc)

    {acc, events_acc} =
      if acc.started do
        {acc, events_acc}
      else
        can_start = is_binary(acc.id) and is_binary(acc.name) and acc.name != ""

        if can_start do
          partial = %{id: acc.id, name: acc.name}
          {acc, events_acc ++ [Event.tool_call_started(partial)]}
        else
          {acc, events_acc}
        end
      end

    {arguments, acc} = extract_arguments_delta(tc, acc)

    acc = %{acc | arguments_parts: acc.arguments_parts ++ [arguments]}
    {acc, maybe_emit_tool_delta(acc, arguments, events_acc)}
  end

  defp maybe_set_tool_id(acc, tc) do
    case Map.get(tc, "id") do
      id when is_binary(id) and not is_nil(acc.id) -> acc
      id when is_binary(id) -> %{acc | id: id}
      _other -> acc
    end
  end

  defp maybe_set_tool_name(acc, tc) do
    case tc do
      %{"function" => %{"name" => name}} when is_binary(name) and not is_nil(acc.name) ->
        acc

      %{"function" => %{"name" => name}} when is_binary(name) ->
        %{acc | name: name}

      _other ->
        acc
    end
  end

  defp extract_arguments_delta(tc, acc) do
    case tc do
      %{"function" => %{"arguments" => args}} when is_binary(args) and args != "" ->
        {args, acc}

      _other ->
        {"", acc}
    end
  end

  defp maybe_emit_tool_delta(_acc, "", events_acc), do: events_acc

  defp maybe_emit_tool_delta(acc, arguments, events_acc) do
    if acc.started do
      partial = %{id: acc.id, name: acc.name, arguments: arguments}
      events_acc ++ [Event.tool_call_delta(partial)]
    else
      events_acc
    end
  end

  # ---------------------------------------------------------------------------
  # Finalize a single tool call
  # ---------------------------------------------------------------------------

  defp finalize_tool_call(acc) do
    with {:ok, name} <- require_tool_name(acc),
         {:ok, arguments} <- decode_arguments(acc) do
      {:ok, ToolCall.new(name, arguments, id: acc.id)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_tool_name(%{name: name}) when is_binary(name) and name != "", do: {:ok, name}
  defp require_tool_name(%{name: name}) when is_binary(name), do: {:error, :empty_name}
  defp require_tool_name(_acc), do: {:error, :missing_name}

  defp decode_arguments(acc) do
    json =
      acc.arguments_parts
      |> Enum.join()

    case String.trim(json) do
      "" -> {:ok, %{}}
      trimmed -> decode_arguments_json(trimmed)
    end
  end

  defp decode_arguments_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error, "expected JSON object"}

      {:error, %Jason.DecodeError{} = err} ->
        message =
          err
          |> Exception.message()
          |> redact_error_message()

        {:error, "invalid JSON: #{message}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Usage normalization
  # ---------------------------------------------------------------------------

  @usage_known_keys [
    {"prompt_tokens", :prompt_tokens},
    {"completion_tokens", :completion_tokens},
    {"total_tokens", :total_tokens}
  ]

  defp normalize_usage(usage) when is_map(usage) do
    known = normalize_known_usage(usage)

    usage
    |> Enum.reduce(known, fn {key, value}, acc ->
      if known_key?(key) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp normalize_known_usage(usage) do
    Enum.reduce(@usage_known_keys, %{}, fn {str_key, atom_key}, acc ->
      cond do
        Map.has_key?(usage, str_key) -> Map.put(acc, atom_key, Map.fetch!(usage, str_key))
        Map.has_key?(usage, atom_key) -> Map.put(acc, atom_key, Map.fetch!(usage, atom_key))
        true -> acc
      end
    end)
  end

  defp known_key?(key) do
    Enum.any?(@usage_known_keys, fn {str_key, atom_key} ->
      key == str_key or key == atom_key
    end)
  end

  # ---------------------------------------------------------------------------
  # Redaction helpers
  # ---------------------------------------------------------------------------

  defp redact_error_message(message) when is_binary(message) do
    message
    |> String.slice(0, @max_error_message_length)
  end

  defp redact_error_message(message), do: message
end
