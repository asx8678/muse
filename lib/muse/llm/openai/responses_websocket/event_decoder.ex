defmodule Muse.LLM.OpenAI.ResponsesWebsocket.EventDecoder do
  @moduledoc """
  Decodes OpenAI Responses WebSocket frames into canonical Muse LLM events.

  The decoder is intentionally conservative: only a fixed allow-list of provider
  event type strings is interpreted. Unknown event strings are ignored and are
  never converted into atoms. Malformed or provider-error frames are converted to
  redacted `:provider_error` events and a redacted terminal error reason.
  """

  alias Muse.{EventPayloadRedactor, MetadataSanitizer}
  alias Muse.LLM.{Event, Response}

  @max_summary_string_length 500

  defstruct content: "",
            response_id: nil,
            usage: nil,
            finish_reason: nil,
            assistant_completed?: false,
            response_completed?: false,
            failed?: false,
            error_reason: nil

  @type t :: %__MODULE__{}

  @doc """
  Return a fresh decoder state.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Decode one provider frame.
  """
  @spec feed(t(), term()) :: {[Event.t()], t()}
  def feed(%__MODULE__{failed?: true} = state, _frame), do: {[], state}

  def feed(%__MODULE__{} = state, frame) do
    case decode_frame(frame) do
      {:ok, map} -> process_frame(state, map)
      {:error, reason} -> fail(state, {:malformed_provider_frame, reason})
    end
  end

  @doc """
  Build the final response and any completion events still owed.
  """
  @spec finalize(t()) :: {:ok, Response.t(), [Event.t()]} | {:error, term()}
  def finalize(%__MODULE__{failed?: true, error_reason: reason}), do: {:error, reason}

  def finalize(%__MODULE__{} = state) do
    if response_seen?(state) do
      response =
        Response.new(
          id: state.response_id,
          content: content_or_nil(state.content),
          text: content_or_nil(state.content),
          usage: state.usage,
          finish_reason: state.finish_reason,
          provider_state: provider_state(state),
          raw: nil
        )

      {:ok, response, completion_events(state)}
    else
      {:error, safe_summary({:provider_ws_error, "WebSocket stream ended without a response"})}
    end
  end

  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{failed?: failed?}), do: failed?

  @spec error_reason(t()) :: term()
  def error_reason(%__MODULE__{error_reason: nil}) do
    safe_summary({:provider_ws_error, "WebSocket stream failed"})
  end

  def error_reason(%__MODULE__{error_reason: reason}), do: reason

  defp decode_frame(frame) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, decoded} ->
        {:error,
         %{
           reason: "WebSocket provider frame must decode to a JSON object",
           frame: safe_summary(decoded)
         }}

      {:error, _reason} ->
        {:error,
         %{
           reason: "malformed JSON WebSocket provider frame",
           frame: safe_string(frame)
         }}
    end
  end

  defp decode_frame(frame) when is_map(frame), do: {:ok, frame}

  defp decode_frame(frame) do
    {:error,
     %{
       reason: "WebSocket provider frame must be a map or JSON string",
       frame: safe_summary(frame)
     }}
  end

  defp process_frame(state, frame) do
    case event_type(frame) do
      "response.output_text.delta" ->
        process_text_delta(state, frame)

      "response.output_text.done" ->
        process_text_done(state, frame)

      "response.completed" ->
        process_response_completed(state, frame)

      "response.created" ->
        {[], update_response_metadata(state, frame)}

      "response.in_progress" ->
        {[], update_response_metadata(state, frame)}

      "response.error" ->
        provider_error(state, frame)

      "response.failed" ->
        provider_error(state, frame)

      "error" ->
        provider_error(state, frame)

      nil ->
        {[], state}

      type when is_binary(type) ->
        {[], state}

      _other ->
        {[], state}
    end
  end

  defp process_text_delta(state, frame) do
    case field(frame, "delta") do
      delta when is_binary(delta) ->
        new_state = %{update_response_metadata(state, frame) | content: state.content <> delta}
        {[Event.assistant_delta(delta)], new_state}

      _other ->
        fail(
          state,
          malformed_known_frame(frame, "response.output_text.delta requires string delta")
        )
    end
  end

  defp process_text_done(state, frame) do
    text = field(frame, "text")

    cond do
      is_binary(text) ->
        complete_assistant(%{update_response_metadata(state, frame) | content: text})

      is_binary(state.content) and state.content != "" ->
        complete_assistant(update_response_metadata(state, frame))

      true ->
        fail(
          state,
          malformed_known_frame(frame, "response.output_text.done requires string text")
        )
    end
  end

  defp process_response_completed(state, frame) do
    state = update_response_metadata(state, frame)

    events = []
    {assistant_events, state} = maybe_complete_assistant(state)
    events = events ++ assistant_events

    state = %{state | response_completed?: true}
    events = events ++ [Event.response_completed(state.usage)]

    {events, state}
  end

  defp complete_assistant(%__MODULE__{assistant_completed?: true} = state), do: {[], state}

  defp complete_assistant(%__MODULE__{} = state) do
    event = Event.assistant_completed(content_or_nil(state.content))
    {[event], %{state | assistant_completed?: true}}
  end

  defp maybe_complete_assistant(%__MODULE__{assistant_completed?: true} = state), do: {[], state}

  defp maybe_complete_assistant(%__MODULE__{content: content} = state)
       when is_binary(content) and content != "" do
    complete_assistant(state)
  end

  defp maybe_complete_assistant(state), do: {[], state}

  defp provider_error(state, frame) do
    error_payload =
      first_present([
        field(frame, "error"),
        field(frame, "message"),
        field(frame, "reason"),
        frame
      ])

    fail(update_response_metadata(state, frame), {:provider_ws_error, error_payload})
  end

  defp fail(state, reason) do
    redacted = safe_summary(reason)
    {[Event.provider_error(redacted)], %{state | failed?: true, error_reason: redacted}}
  end

  defp completion_events(state) do
    {assistant_events, state} = maybe_complete_assistant(state)

    response_events =
      if state.response_completed? do
        []
      else
        [Event.response_completed(state.usage)]
      end

    assistant_events ++ response_events
  end

  defp update_response_metadata(state, frame) do
    response = field(frame, "response")

    %{
      state
      | response_id:
          safe_string_or_nil(
            first_present([
              field(frame, "response_id"),
              field(frame, "id"),
              field(response, "id"),
              state.response_id
            ])
          ),
        usage:
          safe_usage(
            first_present([
              field(frame, "usage"),
              field(response, "usage"),
              state.usage
            ])
          ),
        finish_reason:
          safe_string_or_nil(
            first_present([
              field(frame, "finish_reason"),
              field(response, "finish_reason"),
              state.finish_reason
            ])
          )
    }
  end

  defp malformed_known_frame(frame, reason) do
    type = event_type(frame)

    {:malformed_provider_frame,
     %{
       type: safe_string_or_nil(type),
       reason: reason,
       frame: safe_summary(frame)
     }}
  end

  defp response_seen?(%__MODULE__{response_completed?: true}), do: true
  defp response_seen?(%__MODULE__{response_id: id}) when is_binary(id) and id != "", do: true

  defp response_seen?(%__MODULE__{content: content}) when is_binary(content) and content != "",
    do: true

  defp response_seen?(_state), do: false

  defp provider_state(%__MODULE__{response_id: nil}), do: nil
  defp provider_state(%__MODULE__{response_id: id}), do: %{previous_response_id: id}

  defp event_type(frame), do: field(frame, "type") || field(frame, "event")

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key(key))
    end
  end

  defp field(_other, _key), do: nil

  defp atom_key("code"), do: :code
  defp atom_key("delta"), do: :delta
  defp atom_key("error"), do: :error
  defp atom_key("event"), do: :event
  defp atom_key("finish_reason"), do: :finish_reason
  defp atom_key("id"), do: :id
  defp atom_key("message"), do: :message
  defp atom_key("reason"), do: :reason
  defp atom_key("response"), do: :response
  defp atom_key("response_id"), do: :response_id
  defp atom_key("status"), do: :status
  defp atom_key("text"), do: :text
  defp atom_key("type"), do: :type
  defp atom_key("usage"), do: :usage
  defp atom_key(_key), do: nil

  defp first_present(values) do
    Enum.find(values, &(not is_nil(&1) and &1 != ""))
  end

  defp content_or_nil(""), do: nil
  defp content_or_nil(content), do: content

  defp safe_string_or_nil(nil), do: nil
  defp safe_string_or_nil(value) when is_binary(value), do: safe_string(value)

  defp safe_string_or_nil(value),
    do: value |> inspect(limit: 10, printable_limit: 120) |> safe_string()

  defp safe_usage(nil), do: nil
  defp safe_usage(usage) when is_map(usage), do: safe_summary(usage)
  defp safe_usage(_usage), do: nil

  defp safe_string(value) when is_binary(value) do
    value
    |> EventPayloadRedactor.redact_string()
    |> String.slice(0, @max_summary_string_length)
  end

  defp safe_summary(term) when is_binary(term), do: safe_string(term)

  defp safe_summary(term) do
    term
    |> EventPayloadRedactor.redact()
    |> MetadataSanitizer.sanitize(
      max_depth: 4,
      max_map_keys: 20,
      max_list_length: 10,
      max_string_len: @max_summary_string_length
    )
  rescue
    _exception ->
      term
      |> inspect(limit: 10, printable_limit: @max_summary_string_length)
      |> EventPayloadRedactor.redact_string()
      |> String.slice(0, @max_summary_string_length)
  end
end
