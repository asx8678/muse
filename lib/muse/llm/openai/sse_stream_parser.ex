defmodule Muse.LLM.OpenAI.SSEStreamParser do
  @moduledoc """
  Parses OpenAI-compatible SSE streams into normalized Muse events and responses.

  Pure, stateless module for parsing Server-Sent Events frames from Chat
  Completions streaming responses. No HTTP, no network, no side effects.

  ## Usage

      raw = File.read!("test/fixtures/chat_completions/sse_text_delta.txt")
      acc  = SSEStreamParser.new_accumulator()
      {events, acc} = SSEStreamParser.process_frames(SSEStreamParser.parse_frames(raw), acc)
      {final_events, response} = SSEStreamParser.finalize(acc)
  """

  alias Muse.LLM.{Event, Response, ToolCall}

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type frame :: {:data, map()} | {:done, :done} | {:error, term()}

  @type tool_call_acc :: %{
          id: String.t() | nil,
          name: String.t() | nil,
          arguments: String.t(),
          raw: map() | nil
        }

  @type accumulator :: %{
          id: String.t() | nil,
          content: String.t(),
          tool_calls: %{non_neg_integer() => tool_call_acc()},
          usage: map() | nil,
          finish_reason: String.t() | nil,
          started: boolean()
        }

  # ---------------------------------------------------------------------------
  # Accumulator
  # ---------------------------------------------------------------------------

  @doc """
  Create a new accumulator for processing SSE frames.
  """
  @spec new_accumulator() :: accumulator()
  def new_accumulator do
    %{id: nil, content: "", tool_calls: %{}, usage: nil, finish_reason: nil, started: false}
  end

  # ---------------------------------------------------------------------------
  # Frame parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parse raw SSE text into a list of frames.

  Each frame is `{:data, map()}` for valid JSON data, `{:done, :done}` for
  the `[DONE]` sentinel, or `{:error, term()}` for invalid/undecodable data.
  """
  @spec parse_frames(String.t()) :: [frame()]
  def parse_frames(raw_sse) when is_binary(raw_sse) do
    raw_sse
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(&parse_sse_block/1)
  end

  defp parse_sse_block(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_sse_line/1)
  end

  defp parse_sse_line("data: [DONE]"), do: [{:done, :done}]
  defp parse_sse_line("data: " <> data), do: [decode_data_line(data)]
  defp parse_sse_line("data:" <> data), do: [decode_data_line(String.trim_leading(data))]
  defp parse_sse_line(_unrecognized), do: []

  defp decode_data_line(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> {:data, decoded}
      {:ok, other} -> {:error, {:invalid_sse_data, other}}
      {:error, reason} -> {:error, {:invalid_sse_json, Exception.message(reason)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Frame processing
  # ---------------------------------------------------------------------------

  @doc """
  Process a list of frames through the accumulator, emitting events.

  Returns `{events, accumulator}` where events is the list of normalized
  `Muse.LLM.Event` structs accumulated from all frames.
  """
  @spec process_frames([frame()], accumulator()) :: {[Event.t()], accumulator()}
  def process_frames(frames, acc) when is_list(frames) do
    Enum.reduce(frames, {[], acc}, fn frame, {events, acc} ->
      {new_events, acc} = process_frame(frame, acc)
      {events ++ new_events, acc}
    end)
  end

  @doc """
  Process a single frame, updating the accumulator and emitting events.
  """
  @spec process_frame(frame(), accumulator()) :: {[Event.t()], accumulator()}
  def process_frame({:done, :done}, acc), do: {[], acc}

  def process_frame({:error, reason}, acc) do
    {[Event.provider_error(reason)], acc}
  end

  def process_frame({:data, %{"error" => error}}, acc) do
    {[Event.provider_error(error)], acc}
  end

  def process_frame({:data, data}, acc) when is_map(data) do
    acc = %{acc | id: data["id"] || acc.id}

    case get_in(data, ["choices", Access.at(0)]) do
      nil ->
        # Usage-only chunk (stream_options include_usage)
        {[], maybe_extract_usage(data, acc)}

      choice ->
        {delta_events, acc} = process_choice(choice, acc)
        {delta_events, maybe_extract_usage(data, acc)}
    end
  end

  # ---------------------------------------------------------------------------
  # Choice / delta processing
  # ---------------------------------------------------------------------------

  defp process_choice(choice, acc) do
    delta = Map.get(choice, "delta", %{})
    finish_reason = choice["finish_reason"]

    acc =
      if is_binary(finish_reason) do
        %{acc | finish_reason: finish_reason}
      else
        acc
      end

    {role_events, acc} = maybe_emit_started(delta, acc)
    {content_events, acc} = process_content_delta(delta, acc)
    {tool_events, acc} = process_tool_call_deltas(delta, acc)

    {role_events ++ content_events ++ tool_events, acc}
  end

  defp maybe_emit_started(%{"role" => "assistant"}, %{started: false} = acc) do
    {[Event.response_started()], %{acc | started: true}}
  end

  defp maybe_emit_started(_delta, acc), do: {[], acc}

  defp process_content_delta(%{"content" => content}, acc) when is_binary(content) do
    {[Event.assistant_delta(content)], %{acc | content: acc.content <> content}}
  end

  defp process_content_delta(_delta, acc), do: {[], acc}

  # ---------------------------------------------------------------------------
  # Tool call delta processing
  # ---------------------------------------------------------------------------

  defp process_tool_call_deltas(%{"tool_calls" => tool_calls}, acc) when is_list(tool_calls) do
    Enum.reduce(tool_calls, {[], acc}, fn tc_delta, {events, acc} ->
      process_tool_call_delta(tc_delta, events, acc)
    end)
  end

  defp process_tool_call_deltas(_delta, acc), do: {[], acc}

  defp process_tool_call_delta(tc_delta, events, acc) do
    index = Map.get(tc_delta, "index", 0)

    cond do
      # New tool call — has id and function.name
      has_id_and_name?(tc_delta) ->
        id = tc_delta["id"]
        function = tc_delta["function"]
        name = function["name"]
        arguments = Map.get(function, "arguments", "")

        tc_acc = %{id: id, name: name, arguments: arguments, raw: tc_delta}
        acc = %{acc | tool_calls: Map.put(acc.tool_calls, index, tc_acc)}

        partial = ToolCall.new(name, %{}, id: id, raw: tc_delta)
        {events ++ [Event.tool_call_started(partial)], acc}

      # Argument continuation — has function.arguments delta
      has_arguments_delta?(tc_delta) and Map.has_key?(acc.tool_calls, index) ->
        existing = Map.fetch!(acc.tool_calls, index)
        arg_delta = tc_delta["function"]["arguments"]
        updated = %{existing | arguments: existing.arguments <> arg_delta}
        acc = %{acc | tool_calls: Map.put(acc.tool_calls, index, updated)}

        partial = %{
          id: existing.id,
          name: existing.name,
          arguments_delta: arg_delta,
          index: index
        }

        {events ++ [Event.tool_call_delta(partial)], acc}

      true ->
        {events, acc}
    end
  end

  defp has_id_and_name?(tc_delta) do
    is_map(tc_delta) and Map.has_key?(tc_delta, "id") and
      is_map(tc_delta["function"]) and is_binary(tc_delta["function"]["name"])
  end

  defp has_arguments_delta?(tc_delta) do
    is_map(tc_delta) and is_map(tc_delta["function"]) and
      Map.has_key?(tc_delta["function"], "arguments")
  end

  # ---------------------------------------------------------------------------
  # Usage
  # ---------------------------------------------------------------------------

  defp maybe_extract_usage(data, acc) do
    case Map.get(data, "usage") do
      nil -> acc
      usage when is_map(usage) -> %{acc | usage: normalize_usage(usage)}
      _ -> acc
    end
  end

  defp normalize_usage(usage) do
    known = [
      {"prompt_tokens", :prompt_tokens},
      {"completion_tokens", :completion_tokens},
      {"total_tokens", :total_tokens}
    ]

    normalized =
      Enum.reduce(known, %{}, fn {str_key, atom_key}, acc ->
        case Map.get(usage, str_key) || Map.get(usage, atom_key) do
          nil -> acc
          value -> Map.put(acc, atom_key, value)
        end
      end)

    known_keys = Enum.flat_map(known, fn {s, a} -> [s, a] end)

    usage
    |> Map.drop(known_keys)
    |> Enum.reduce(normalized, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  # ---------------------------------------------------------------------------
  # Finalization
  # ---------------------------------------------------------------------------

  @doc """
  Finalize the accumulator, emitting final events and assembling the Response.

  Returns `{final_events, response}` where final_events includes
  `:assistant_completed` (if text was produced), `:tool_call_completed`
  for each tool call, and `:response_completed`.
  """
  @spec finalize(accumulator()) :: {[Event.t()], Response.t()}
  def finalize(acc) do
    events = []

    events =
      if acc.content != "" do
        events ++ [Event.assistant_completed(acc.content)]
      else
        events
      end

    {tool_calls, tool_events} = finalize_tool_calls(acc.tool_calls)
    events = events ++ tool_events

    content = if(acc.content != "", do: acc.content, else: nil)

    response =
      Response.new(
        id: acc.id,
        content: content,
        text: content,
        tool_calls: tool_calls,
        usage: acc.usage,
        finish_reason: acc.finish_reason
      )

    events = events ++ [Event.response_completed(acc.usage)]
    {events, response}
  end

  defp finalize_tool_calls(tool_calls_map) do
    tool_calls_map
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {_index, tc_acc} -> finalize_tool_call(tc_acc) end)
    |> Enum.reduce({[], []}, fn {tc, tc_events}, {tcs, evts} ->
      {tcs ++ [tc], evts ++ tc_events}
    end)
  end

  defp finalize_tool_call(tc_acc) do
    arguments = parse_tool_arguments(tc_acc.arguments)
    tool_call = ToolCall.new(tc_acc.name, arguments, id: tc_acc.id, raw: tc_acc.raw)
    {tool_call, [Event.tool_call_completed(tool_call)]}
  end

  defp parse_tool_arguments(""), do: %{}

  defp parse_tool_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, _other} -> %{}
      {:error, _reason} -> %{}
    end
  end

  defp parse_tool_arguments(_), do: %{}

  # ---------------------------------------------------------------------------
  # Full pipeline
  # ---------------------------------------------------------------------------

  @doc """
  Full pipeline: parse raw SSE text and return all events plus the final response.

  Returns `{all_events, result}` where `result` is `{:ok, response}` on a
  clean stream or `{:error, :provider_error}` if any error frames were seen.
  """
  @spec parse_stream(String.t()) :: {[Event.t()], {:ok, Response.t()} | {:error, :provider_error}}
  def parse_stream(raw_sse) when is_binary(raw_sse) do
    frames = parse_frames(raw_sse)
    acc = new_accumulator()
    {stream_events, acc} = process_frames(frames, acc)
    {final_events, response} = finalize(acc)
    all_events = stream_events ++ final_events

    has_error = Enum.any?(all_events, &match?(%Event{type: :provider_error}, &1))
    result = if has_error, do: {:error, :provider_error}, else: {:ok, response}

    {all_events, result}
  end
end
