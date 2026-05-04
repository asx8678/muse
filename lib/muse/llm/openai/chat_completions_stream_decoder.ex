defmodule Muse.LLM.OpenAI.ChatCompletionsStreamDecoder do
  @moduledoc """
  Decodes an OpenAI-compatible streaming Chat Completions SSE stream into
  normalized `Muse.LLM.Event` structs and a final `Muse.LLM.Response`.

  Accepts parsed JSON chunk maps (not raw SSE text). Each chunk represents
  a single `data:` line from the SSE stream.  `[DONE]` sentinel lines are
  excluded by the caller before passing chunks to `decode/2`.

  ## Chunk format (OpenAI streaming Delta format)

      %{
        "id" => "chatcmpl_123",
        "object" => "chat.completion.chunk",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "content" => "Hello",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_abc",
                  "type" => "function",
                  "function" => %{"name" => "read_file", "arguments" => "{\"path\":"}
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

  ## Event emission

  The decoder emits these events during `decode/2`:

    * `:assistant_delta` — text content deltas
    * `:tool_call_started` — once per tool call when its `id`/`name` is first seen
    * `:tool_call_delta` — argument JSON string deltas
    * `:tool_call_completed` — during finalization, with accumulated arguments
      decoded into a map and wrapped in `%Muse.LLM.ToolCall{}`
    * `:provider_error` — for malformed argument JSON (redacted)

  ## Usage

      {:ok, response} = ChatCompletionsStreamDecoder.decode(chunks, &emit/1)
  """

  alias Muse.LLM.{Event, Response, ToolCall}

  @max_error_message_length 300

  defstruct [
    :id,
    text_chunks: [],
    pending_tool_calls: %{},
    tool_call_order: [],
    completed_tool_calls: [],
    usage: nil,
    finish_reason: nil
  ]

  @type pending_tool_call :: %{
          required(:index) => integer(),
          required(:id) => String.t() | nil,
          required(:name) => String.t() | nil,
          required(:arg_chunks) => [String.t()]
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          text_chunks: [String.t()],
          pending_tool_calls: %{integer() => pending_tool_call()},
          tool_call_order: [integer()],
          completed_tool_calls: [ToolCall.t()],
          usage: map() | nil,
          finish_reason: String.t() | nil
        }

  @doc """
  Decode a list of parsed SSE chunk maps into events and a final Response.

  Emits events via `emit_fn` (defaults to no-op). Returns
  `{:ok, %Muse.LLM.Response{}}` on success.

  ## Examples

      chunks = [
        %{"id" => "cmpl_1", "object" => "chat.completion.chunk",
          "choices" => [%{"index" => 0, "delta" => %{"content" => "Hello"}}]},
        %{"id" => "cmpl_1", "object" => "chat.completion.chunk",
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}
      ]

      {:ok, resp} = ChatCompletionsStreamDecoder.decode(chunks)
      resp.content == "Hello"
  """
  @spec decode([map()], (Event.t() -> :ok)) :: {:ok, Response.t()}
  def decode(chunks, emit_fn \\ fn _ -> :ok end)

  def decode(chunks, emit_fn) when is_list(chunks) and is_function(emit_fn, 1) do
    state = %__MODULE__{}
    state = Enum.reduce(chunks, state, &safe_process_chunk(&1, &2, emit_fn))
    state = finalize_pending_tool_calls(state, emit_fn)
    {:ok, build_response(state)}
  end

  # ---------------------------------------------------------------------------
  # Chunk processing — top-level dispatch
  # ---------------------------------------------------------------------------

  defp safe_process_chunk(chunk, state, emit_fn) when is_map(chunk) do
    state
    |> maybe_set_id(chunk)
    |> maybe_process_choices(chunk, emit_fn)
    |> maybe_set_usage(chunk)
  end

  defp safe_process_chunk(_chunk, state, _emit_fn), do: state

  defp maybe_set_id(state, %{"id" => id}) when is_binary(id), do: %{state | id: id}
  defp maybe_set_id(state, _chunk), do: state

  defp maybe_set_usage(state, %{"usage" => usage}) when is_map(usage), do: %{state | usage: usage}
  defp maybe_set_usage(state, _chunk), do: state

  # ---------------------------------------------------------------------------
  # Choices processing
  # ---------------------------------------------------------------------------

  defp maybe_process_choices(state, %{"choices" => choices}, emit_fn) when is_list(choices) do
    case choices do
      [choice | _] when is_map(choice) ->
        state
        |> process_finish_reason(choice)
        |> process_delta(choice, emit_fn)

      _ ->
        state
    end
  end

  defp maybe_process_choices(state, _chunk, _emit_fn), do: state

  defp process_finish_reason(state, %{"finish_reason" => reason}) when is_binary(reason) do
    %{state | finish_reason: reason}
  end

  defp process_finish_reason(state, _choice), do: state

  # ---------------------------------------------------------------------------
  # Delta processing — content and tool calls
  # ---------------------------------------------------------------------------

  defp process_delta(state, %{"delta" => delta}, emit_fn) when is_map(delta) do
    state
    |> process_content_delta(delta, emit_fn)
    |> process_tool_call_deltas(delta, emit_fn)
  end

  defp process_delta(state, _choice, _emit_fn), do: state

  defp process_content_delta(state, %{"content" => content}, emit_fn) when is_binary(content) do
    emit_fn.(Event.assistant_delta(content))
    %{state | text_chunks: state.text_chunks ++ [content]}
  end

  defp process_content_delta(state, %{"content" => nil}, _emit_fn), do: state
  defp process_content_delta(state, _delta, _emit_fn), do: state

  # ---------------------------------------------------------------------------
  # Tool call delta processing
  # ---------------------------------------------------------------------------

  defp process_tool_call_deltas(state, %{"tool_calls" => tool_calls}, emit_fn)
       when is_list(tool_calls) do
    Enum.reduce(tool_calls, state, fn tc, acc ->
      process_tool_call_entry(acc, tc, emit_fn)
    end)
  end

  defp process_tool_call_deltas(state, _delta, _emit_fn), do: state

  defp process_tool_call_entry(state, %{"index" => idx} = entry, emit_fn) do
    cond do
      Map.has_key?(entry, "id") ->
        start_tool_call(state, entry, idx, emit_fn)

      not Map.has_key?(state.pending_tool_calls, idx) and
          is_binary(get_in(entry, ["function", "name"])) ->
        # First-time entry with function.name but no explicit id — still valid
        start_tool_call(state, entry, idx, emit_fn)

      true ->
        update_tool_call_arguments(state, entry, idx, emit_fn)
    end
  end

  # ---------------------------------------------------------------------------
  # Start a new tool call
  # ---------------------------------------------------------------------------

  defp start_tool_call(state, entry, idx, emit_fn) do
    id = entry["id"] || "tc_#{idx}"
    name = get_in(entry, ["function", "name"]) || "unknown"
    args = get_in(entry, ["function", "arguments"]) || ""

    pending = %{
      index: idx,
      id: id,
      name: name,
      arg_chunks: if(args != "", do: [args], else: [])
    }

    pcs = Map.put(state.pending_tool_calls, idx, pending)

    order =
      if idx in state.tool_call_order,
        do: state.tool_call_order,
        else: state.tool_call_order ++ [idx]

    partial = %{id: id, name: name, index: idx}
    emit_fn.(Event.tool_call_started(partial))

    %{state | pending_tool_calls: pcs, tool_call_order: order}
  end

  # ---------------------------------------------------------------------------
  # Update arguments for an existing tool call
  # ---------------------------------------------------------------------------

  defp update_tool_call_arguments(state, entry, idx, emit_fn) do
    case Map.fetch(state.pending_tool_calls, idx) do
      {:ok, pending} ->
        args = get_in(entry, ["function", "arguments"]) || ""

        if args != "" do
          emit_fn.(Event.tool_call_delta(%{index: idx, arguments: args}))
        end

        updated = %{pending | arg_chunks: pending.arg_chunks ++ [args]}
        %{state | pending_tool_calls: Map.put(state.pending_tool_calls, idx, updated)}

      :error ->
        # Delta for an unknown index — this shouldn't happen in a well-formed
        # stream but we handle gracefully by emitting a provider_error.
        emit_fn.(
          Event.provider_error(
            redact_message("tool call delta for unknown index #{inspect(idx)}")
          )
        )

        state
    end
  end

  # ---------------------------------------------------------------------------
  # Finalization — complete all pending tool calls
  # ---------------------------------------------------------------------------

  defp finalize_pending_tool_calls(state, emit_fn) do
    completed =
      state.tool_call_order
      |> Enum.reduce([], fn idx, acc ->
        case Map.fetch(state.pending_tool_calls, idx) do
          {:ok, pending} ->
            case decode_tool_call_arguments(pending, emit_fn) do
              {:ok, arguments} ->
                tc = ToolCall.new(pending.name, arguments, id: pending.id)
                emit_fn.(Event.tool_call_completed(tc))
                acc ++ [tc]

              {:error, _redacted_reason} ->
                # Tool call completes with empty arguments on decode failure
                tc = ToolCall.new(pending.name, %{}, id: pending.id)
                emit_fn.(Event.tool_call_completed(tc))
                acc ++ [tc]
            end

          :error ->
            acc
        end
      end)

    %{state | completed_tool_calls: completed, pending_tool_calls: %{}}
  end

  defp decode_tool_call_arguments(pending, emit_fn) do
    json = Enum.join(pending.arg_chunks)

    case json do
      "" ->
        {:ok, %{}}

      trimmed when is_binary(trimmed) ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, decoded}

          {:ok, _other} ->
            msg = "tool call #{pending.id} arguments did not decode to a JSON object"
            emit_fn.(Event.provider_error(redact_message(msg)))
            {:error, msg}

          {:error, %Jason.DecodeError{} = reason} ->
            msg =
              "invalid JSON in tool call #{pending.id} arguments: #{Exception.message(reason)}"

            redacted = redact_message(msg)
            emit_fn.(Event.provider_error(redacted))
            {:error, redacted}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Response assembly
  # ---------------------------------------------------------------------------

  defp build_response(state) do
    text =
      case state.text_chunks do
        [] -> nil
        chunks -> Enum.join(chunks)
      end

    finish_reason =
      state.finish_reason ||
        if state.completed_tool_calls != [],
          do: "tool_calls",
          else: nil

    Response.new(
      id: state.id,
      content: text,
      tool_calls: state.completed_tool_calls,
      usage: state.usage,
      finish_reason: finish_reason
    )
  end

  # ---------------------------------------------------------------------------
  # Redaction helpers
  # ---------------------------------------------------------------------------

  defp redact_message(msg) when is_binary(msg) do
    msg
    |> Muse.EventPayloadRedactor.redact_string()
    |> String.slice(0, @max_error_message_length)
  end

  defp redact_message(msg) do
    msg
    |> inspect()
    |> Muse.EventPayloadRedactor.redact_string()
    |> String.slice(0, @max_error_message_length)
  end
end
