defmodule Muse.LLM.OpenAI.ResponsesWSDecoder do
  @moduledoc """
  Decodes OpenAI Responses API WebSocket event frames into canonical Muse events.

  This decoder is deliberately pure: it takes a state and a decoded JSON frame map,
  and returns an updated state and a list of `Muse.LLM.Event.t()`. It does not
  perform JSON decoding, network I/O, or auth resolution.

  ## Supported event types

    * `response.output_text.delta` → `:assistant_delta`
    * `response.output_item.added` (function_call) → `:tool_call_started`
    * `response.function_call_arguments.delta` → `:tool_call_delta`
    * `response.function_call_arguments.done` → accumulates arguments
    * `response.output_item.done` (function_call) → `:tool_call_completed`
    * `response.completed` → `:assistant_completed` (if text), `:response_completed`
    * `response.failed` → `:provider_error`, marks stream as failed

  Unknown event types are safely ignored.
  """

  alias Muse.LLM.{Event, Response, ToolCall}

  @type tool_call_acc :: %{
          id: String.t() | nil,
          name: String.t() | nil,
          call_id: String.t() | nil,
          arguments: String.t()
        }

  @type t :: %__MODULE__{
          text: String.t(),
          tool_calls: [ToolCall.t()],
          pending_tool_calls: %{String.t() => tool_call_acc()},
          response_id: String.t() | nil,
          usage: map() | nil,
          failed?: boolean()
        }

  defstruct text: "",
            tool_calls: [],
            pending_tool_calls: %{},
            response_id: nil,
            usage: nil,
            failed?: false

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), map()) :: {t(), [Event.t()]}
  def feed(state, %{"type" => type} = frame) do
    case type do
      "response.output_text.delta" ->
        feed_text_delta(state, frame)

      "response.output_text.done" ->
        {state, []}

      "response.output_item.added" ->
        feed_output_item_added(state, frame)

      "response.function_call_arguments.delta" ->
        feed_function_call_arguments_delta(state, frame)

      "response.function_call_arguments.done" ->
        feed_function_call_arguments_done(state, frame)

      "response.output_item.done" ->
        feed_output_item_done(state, frame)

      "response.completed" ->
        feed_response_completed(state, frame)

      "response.failed" ->
        {%{state | failed?: true}, [Event.provider_error("response_failed")]}

      _ ->
        {state, []}
    end
  end

  def feed(state, _frame), do: {state, []}

  # -- Text delta ---------------------------------------------------------------

  defp feed_text_delta(state, %{"delta" => delta}) when is_binary(delta) do
    {%{state | text: state.text <> delta}, [Event.assistant_delta(delta)]}
  end

  defp feed_text_delta(state, _frame), do: {state, []}

  # -- Tool call lifecycle -------------------------------------------------------

  defp feed_output_item_added(state, %{"item" => %{"type" => "function_call"} = item}) do
    item_id = item["id"] || item["call_id"] || ""

    pending = %{
      id: item["call_id"] || item["id"],
      name: item["name"],
      call_id: item["call_id"],
      arguments: ""
    }

    new_pending = Map.put(state.pending_tool_calls, item_id, pending)

    tc = ToolCall.new(pending.name || "", %{}, id: pending.id)

    {%{state | pending_tool_calls: new_pending}, [Event.tool_call_started(tc)]}
  end

  defp feed_output_item_added(state, _frame), do: {state, []}

  defp feed_function_call_arguments_delta(state, %{"item_id" => item_id, "delta" => delta})
       when is_binary(item_id) and is_binary(delta) do
    case Map.get(state.pending_tool_calls, item_id) do
      nil ->
        {state, []}

      pending ->
        updated = %{pending | arguments: pending.arguments <> delta}
        new_pending = Map.put(state.pending_tool_calls, item_id, updated)

        tc = ToolCall.new(updated.name || "", %{}, id: updated.id)
        {%{state | pending_tool_calls: new_pending}, [Event.tool_call_delta(tc)]}
    end
  end

  defp feed_function_call_arguments_delta(state, _frame), do: {state, []}

  defp feed_function_call_arguments_done(state, %{"item_id" => item_id, "arguments" => arguments})
       when is_binary(item_id) do
    case Map.get(state.pending_tool_calls, item_id) do
      nil ->
        {state, []}

      pending ->
        updated = %{pending | arguments: arguments}
        new_pending = Map.put(state.pending_tool_calls, item_id, updated)
        {%{state | pending_tool_calls: new_pending}, []}
    end
  end

  defp feed_function_call_arguments_done(state, _frame), do: {state, []}

  defp feed_output_item_done(state, %{"item" => %{"type" => "function_call"} = item}) do
    item_id = item["id"] || item["call_id"] || ""

    {tc, new_pending} =
      case Map.get(state.pending_tool_calls, item_id) do
        nil ->
          name = item["name"] || ""
          args = decode_tool_arguments(item["arguments"])
          tc = ToolCall.new(name, args, id: item["call_id"] || item["id"])
          {tc, state.pending_tool_calls}

        pending ->
          decoded_args = decode_tool_arguments(pending.arguments)
          tc = ToolCall.new(pending.name || "", decoded_args, id: pending.id)
          {tc, Map.delete(state.pending_tool_calls, item_id)}
      end

    {%{state | tool_calls: state.tool_calls ++ [tc], pending_tool_calls: new_pending},
     [Event.tool_call_completed(tc)]}
  end

  defp feed_output_item_done(state, _frame), do: {state, []}

  # -- Response completed --------------------------------------------------------

  defp feed_response_completed(state, %{"response" => response}) when is_map(response) do
    response_id = response["id"]
    usage = decode_usage(response["usage"])

    events =
      if state.text != "" do
        [Event.assistant_completed(state.text)]
      else
        []
      end

    events = events ++ [Event.response_completed(usage)]

    {%{state | response_id: response_id, usage: usage}, events}
  end

  defp feed_response_completed(state, _frame), do: {state, []}

  # -- Helpers -------------------------------------------------------------------

  defp decode_usage(nil), do: nil

  defp decode_usage(usage) when is_map(usage) do
    %{
      prompt_tokens: usage["input_tokens"] || usage["prompt_tokens"],
      completion_tokens: usage["output_tokens"] || usage["completion_tokens"],
      total_tokens: usage["total_tokens"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp decode_tool_arguments(nil), do: %{}

  defp decode_tool_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_arguments(args) when is_map(args), do: args
  defp decode_tool_arguments(_), do: %{}

  @doc """
  Finalize the decoder, returning the final response and any remaining events.

  If the stream failed (`response.failed` was received), the response will have
  `finish_reason: "error"`. Otherwise `finish_reason: "stop"`.

  The returned `provider_state` always includes `previous_response_id` from
  the `response.completed` event's response ID.
  """
  @spec finalize(t()) :: {Response.t(), [Event.t()]}
  def finalize(state) do
    response =
      Response.new(
        id: state.response_id,
        content: if(state.text == "", do: nil, else: state.text),
        text: if(state.text == "", do: nil, else: state.text),
        tool_calls: state.tool_calls,
        usage: state.usage,
        provider_state: %{previous_response_id: state.response_id},
        finish_reason: if(state.failed?, do: "error", else: "stop")
      )

    {response, []}
  end
end
