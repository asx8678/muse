defmodule Muse.LLM.FakeProvider do
  @moduledoc """
  Deterministic offline fake provider for testing and development.

  Implements `Muse.LLM.Provider` with no network dependency.  Every call
  produces the same output for the same input, making it suitable for
  deterministic offline tests.

  ## Default Behavior

  When no script is provided, the fake provider emits a simple assistant
  response derived from the latest user message:

      "Placeholder response: received <latest user message>"

  This covers basic compatibility testing without any configuration.

  ## Scripting via `request.options`

  The fake provider reads scripting instructions from the `options` map
  of `Muse.LLM.Request.t()`.  Supported keys:

    * `:fake_events` — list of script entries to emit in order
    * `:fake_error`  — atom or term to simulate a provider error

  These keys are **ignored** by real providers, so they can safely
  coexist in the request struct.

  ### Script Entry Formats

  Each entry in `:fake_events` can be:

    * `{:assistant_delta, text}`             — emit `:assistant_delta`
    * `{:tool_call, name, args_map}`        — emit `:tool_call_started` → `:tool_call_completed`
    * `{:tool_call, name, args_map, id}`    — emit with specific tool call ID
    * `{:assistant_completed, nil}`          — emit `:assistant_completed`
    * `{:assistant_completed, text}`         — emit `:assistant_completed` with final text
    * `{:response_completed, usage}`         — emit `:response_completed` with usage map
    * `{:error, reason}`                    — emit `:provider_error` and return `{:error, ...}`
    * `{:delay, ms}`                        — pause for `ms` milliseconds (cancellation tests)
    * `%Muse.LLM.Event{}` struct            — emit directly
    * map with `:type`/`:event` key         — converted to `Muse.LLM.Event` and emitted

  ### Map-based entries

  Maps support both atom and string keys, and both `:type`/`:event` keys,
  for compatibility with JSON fixtures:

      %{type: :assistant_delta, text: "hello"}
      %{"event" => "assistant_delta", "text" => "hello"}
      %{"event" => "tool_call", "name" => "read_file", "arguments" => %{}}

  Unknown event types in maps emit `:provider_error` instead of arbitrary events.

  ### Text assembly in the response

  When both `:assistant_delta` and `:assistant_completed` entries appear in
  a script, the response `content` prefers the `:assistant_completed` text
  (the authoritative full text).  If no `:assistant_completed` with text is
  present, `:assistant_delta` fragments are concatenated.

  ### Example

      request = %Muse.LLM.Request{
        provider: :fake,
        model: "fake-planning-model",
        messages: [Muse.LLM.Message.user("add a /version command")],
        options: %{
          fake_events: [
            {:assistant_delta, "I'll inspect the workspace first."},
            {:tool_call, "list_files", %{"path" => "."}},
            {:assistant_delta, "Based on the listing, here is my plan:"},
            {:assistant_completed, "Based on the listing, here is my plan:"},
            {:response_completed, nil}
          ]
        }
      }

  {:ok, response} = Muse.LLM.FakeProvider.stream(request, fn event ->
    IO.inspect(event)
    :ok
  end)

  ## Error Path

  When `:fake_error` is set in `options`, the provider emits a
  `:provider_error` event and returns `{:error, redacted_reason}`.

  When `{:error, reason}` appears inside `:fake_events`, the provider
  emits a `:provider_error` event and returns `{:error, redacted_reason}`
  immediately (no further entries are processed).  This matches real
  provider failure semantics — once the provider errors, the stream is
  over.

  Error data is redacted using `Muse.EventPayloadRedactor` and
  `Muse.MetadataSanitizer` before being returned or emitted.

  ## Tool Call IDs

  When a `:tool_call` script entry does not include an explicit ID, the
  fake provider generates a deterministic ID based on a monotonic counter
  scoped to the request: `"fake_call_<counter>"`.
  """

  @behaviour Muse.LLM.Provider

  alias Muse.LLM.{Event, Request, Response, ToolCall}
  alias Muse.{EventPayloadRedactor, MetadataSanitizer}

  # Script-level event type for tool_call shorthand — not a canonical Event type,
  # but accepted in map-based entries to emit :tool_call_started + :tool_call_completed.
  @script_only_types [:tool_call]

  @impl true
  def stream(%Request{} = request, emit) when is_function(emit, 1) do
    options = safe_options(request.options)

    case classify_options(options) do
      {:error, reason} ->
        emit.(Event.provider_error(reason))
        {:error, reason}

      {:fake_error, reason} ->
        handle_scripted_error(reason, emit)

      {:fake_events, events} ->
        handle_scripted_events(events, emit)

      {:fake_event_batches, _batches} ->
        handle_scripted_batches(request, emit)

      :default ->
        handle_default(request, emit)
    end
  end

  @impl true
  def complete(%Request{} = request, _opts \\ []) do
    options = safe_options(request.options)

    case classify_options(options) do
      {:error, reason} ->
        {:error, reason}

      {:fake_error, reason} ->
        redacted = redact_error(reason)
        {:error, redacted}

      {:fake_events, events} ->
        complete_from_script(events)

      :default ->
        text = default_text(request)
        {:ok, Response.new(content: text, finish_reason: "stop")}
    end
  end

  # Normalize options to a map.  nil → %{}, non-map → error.
  defp safe_options(nil), do: %{}
  defp safe_options(options) when is_map(options), do: options

  defp safe_options(other) do
    {:error, redact_error("request.options must be a map, got: #{inspect(other)}")}
  end

  # Classify an options map into a dispatch instruction.
  defp classify_options({:error, _} = error), do: error

  defp classify_options(options) when is_map(options) do
    cond do
      Map.has_key?(options, :fake_error) ->
        {:fake_error, options[:fake_error]}

      Map.has_key?(options, :fake_events) ->
        {:fake_events, options[:fake_events]}

      Map.has_key?(options, :fake_event_batches) ->
        {:fake_event_batches, options[:fake_event_batches]}

      true ->
        :default
    end
  end

  # ---------------------------------------------------------------------------
  # Default (unscripted) path
  # ---------------------------------------------------------------------------

  # -- Batched iteration path (for tool-loop tests) ---------------------------

  defp handle_scripted_batches(request, emit) do
    iteration = request.options[:fake_iteration] || 0
    batches = request.options[:fake_event_batches] || []

    script =
      if iteration < length(batches) do
        Enum.at(batches, iteration)
      else
        nil
      end

    if script do
      # Delegate to the existing scripted events handler
      handle_scripted_events(script, emit)
    else
      # No more scripts — produce a default response
      # If the request contains tool-role messages, generate a summary
      text = default_text_for_request(request)

      emit.(Event.response_started())
      emit.(Event.assistant_delta(text))
      emit.(Event.assistant_completed(text))
      emit.(Event.response_completed())

      {:ok, Response.new(content: text, finish_reason: "stop")}
    end
  end

  defp default_text_for_request(request) do
    tool_msg_count = count_tool_messages(request)

    if tool_msg_count > 0 do
      "Placeholder response after tool inspection: received #{tool_msg_count} tool result(s)"
    else
      default_text(request)
    end
  end

  defp count_tool_messages(%Request{messages: messages}) when is_list(messages) do
    Enum.count(messages, &(&1.role == :tool))
  end

  defp count_tool_messages(_), do: 0

  defp handle_default(request, emit) do
    text = default_text_for_request(request)

    emit.(Event.response_started())
    emit.(Event.assistant_delta(text))
    emit.(Event.assistant_completed(text))
    emit.(Event.response_completed())

    {:ok, Response.new(content: text, finish_reason: "stop")}
  end

  defp default_text(request) do
    "Placeholder response: received #{Request.latest_user_text(request)}"
  end

  # ---------------------------------------------------------------------------
  # Scripted events path — accumulates state across all entries
  # ---------------------------------------------------------------------------

  defp handle_scripted_events(script, emit) when is_list(script) do
    initial_acc = %{
      deltas: [],
      completed_text: nil,
      tool_calls: [],
      usage: nil,
      counter: 0,
      error: nil
    }

    result =
      Enum.reduce_while(script, initial_acc, fn entry, acc ->
        {events, next_counter} = normalize_script_entry(entry, acc.counter)

        # Emit all normalized events (may be nil for :delay entries)
        if events do
          Enum.each(events, fn %Event{} = event -> emit.(event) end)
        end

        # Accumulate state from emitted events
        new_acc = accumulate_events(events || [], %{acc | counter: next_counter})

        # If an error was encountered, halt — no further entries processed
        if new_acc.error != nil do
          {:halt, new_acc}
        else
          {:cont, new_acc}
        end
      end)

    if result.error != nil do
      {:error, result.error}
    else
      {:ok, build_response_from_acc(result)}
    end
  end

  defp handle_scripted_events(_other, emit) do
    emit.(Event.provider_error("fake_events must be a list"))
    {:error, redact_error("fake_events must be a list")}
  end

  # ---------------------------------------------------------------------------
  # Accumulation — builds response state from emitted events
  # ---------------------------------------------------------------------------

  defp accumulate_events(events, acc) do
    Enum.reduce(events, acc, fn event, acc ->
      case event do
        %Event{type: :assistant_delta, text: text} when is_binary(text) ->
          %{acc | deltas: [text | acc.deltas]}

        %Event{type: :assistant_completed, text: text} when is_binary(text) ->
          # Last assistant_completed with text wins
          %{acc | completed_text: text}

        %Event{type: :assistant_completed} ->
          # nil text — don't overwrite
          acc

        %Event{type: :tool_call_completed, tool_call: %ToolCall{} = tc} ->
          %{acc | tool_calls: acc.tool_calls ++ [tc]}

        %Event{type: :response_completed, usage: usage} when is_map(usage) ->
          %{acc | usage: usage}

        %Event{type: :provider_error, error: reason} ->
          %{acc | error: reason}

        _ ->
          acc
      end
    end)
  end

  defp build_response_from_acc(acc) do
    # Prefer assistant_completed text (authoritative full text).
    # Fall back to concatenated deltas when no completed text is present.
    content =
      case acc.completed_text do
        nil -> acc.deltas |> Enum.reverse() |> Enum.join("")
        text -> text
      end

    finish_reason = if acc.tool_calls != [], do: "tool_calls", else: "stop"

    Response.new(
      content: content,
      tool_calls: acc.tool_calls,
      usage: acc.usage,
      finish_reason: finish_reason
    )
  end

  # ---------------------------------------------------------------------------
  # Normalize script entries → list of Event structs
  # ---------------------------------------------------------------------------

  defp normalize_script_entry({:assistant_delta, text}, counter) when is_binary(text) do
    {[Event.assistant_delta(text)], counter}
  end

  defp normalize_script_entry({:tool_call, name, args}, counter)
       when is_binary(name) and is_map(args) do
    normalize_script_entry({:tool_call, name, args, "fake_call_#{counter}"}, counter)
  end

  defp normalize_script_entry({:tool_call, name, args, id}, counter)
       when is_binary(name) and is_map(args) and is_binary(id) do
    tc = ToolCall.new(name, args, id: id)

    events = [
      Event.tool_call_started(tc),
      Event.tool_call_completed(tc)
    ]

    {events, counter + 1}
  end

  defp normalize_script_entry({:assistant_completed, nil}, counter) do
    {[Event.assistant_completed()], counter}
  end

  defp normalize_script_entry({:assistant_completed, text}, counter) when is_binary(text) do
    {[Event.assistant_completed(text)], counter}
  end

  defp normalize_script_entry({:response_completed, nil}, counter) do
    {[Event.response_completed()], counter}
  end

  defp normalize_script_entry({:response_completed, usage}, counter) when is_map(usage) do
    {[Event.response_completed(usage)], counter}
  end

  defp normalize_script_entry({:error, reason}, counter) do
    redacted = redact_error(reason)
    {[Event.provider_error(redacted)], counter}
  end

  defp normalize_script_entry({:delay, ms}, counter) when is_integer(ms) and ms >= 0 do
    Process.sleep(ms)
    {nil, counter}
  end

  defp normalize_script_entry(%Event{type: :provider_error, error: raw_error} = _event, counter) do
    # %Event{} structs with type :provider_error must also be redacted —
    # a caller may construct an event with an unredacted error field.
    redacted = redact_error(raw_error)
    {[Event.provider_error(redacted)], counter}
  end

  defp normalize_script_entry(%Event{} = event, counter) do
    {[event], counter}
  end

  # Map-based entries — support both atom and string keys, :type and :event fields.
  # Only known event types (and :tool_call script shorthand) are accepted.
  # Unknown types produce :provider_error instead of arbitrary events.
  # :provider_error maps always redact their error field before emitting.
  defp normalize_script_entry(%{} = map, counter) when not is_struct(map) do
    case extract_map_event_type(map) do
      {:ok, :tool_call} ->
        normalize_tool_call_map(map, counter)

      {:ok, :provider_error} ->
        # Always redact the error payload from map-based provider_error entries
        # so secrets (API keys, tokens) never leak through the event or the
        # {:error, reason} return value.
        raw_error = map_get(map, :error)
        redacted = redact_error(raw_error)
        {[Event.provider_error(redacted)], counter}

      {:ok, type} ->
        event = build_event_from_map_type(type, map)
        {[event], counter}

      {:error, reason} ->
        {[Event.provider_error(redact_error(reason))], counter}
    end
  end

  defp normalize_script_entry(other, counter) do
    # Unknown script entry — emit :provider_error, never crash
    {[
       %Event{
         type: :provider_error,
         error: redact_error("unknown script entry: #{inspect(other)}")
       }
     ], counter}
  end

  # ---------------------------------------------------------------------------
  # Map-based entry helpers
  # ---------------------------------------------------------------------------

  # Extract a value from a map using either atom or string key.
  # Prefers atom key, falls back to string key.
  defp map_get(map, atom_key) when is_atom(atom_key) do
    case Map.get(map, atom_key) do
      nil -> Map.get(map, Atom.to_string(atom_key))
      value -> value
    end
  end

  # Extract and validate event type from a map entry.
  # Supports :type / "type" / :event / "event" keys, with atom or string values.
  # Only returns known canonical types or the :tool_call script shorthand.
  defp extract_map_event_type(map) do
    raw_type = map_get(map, :type) || map_get(map, :event)

    type =
      case raw_type do
        atom when is_atom(atom) -> atom
        str when is_binary(str) -> safe_string_to_atom(str)
        _ -> nil
      end

    cond do
      type in Event.event_types() ->
        {:ok, type}

      type in @script_only_types ->
        {:ok, type}

      true ->
        {:error, "unknown event type in map entry: #{inspect(raw_type)}"}
    end
  end

  # Convert a string to an atom only if it already exists in the atom table.
  # Returns nil for unknown strings, preventing atom-table exhaustion.
  defp safe_string_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp normalize_tool_call_map(map, counter) do
    name = map_get(map, :name)
    args = map_get(map, :arguments) || %{}
    id = map_get(map, :id) || "fake_call_#{counter}"

    if is_binary(name) and is_map(args) do
      tc = ToolCall.new(name, args, id: id)
      events = [Event.tool_call_started(tc), Event.tool_call_completed(tc)]
      {events, counter + 1}
    else
      reason = "invalid tool_call map: name must be a string and arguments must be a map"
      {[Event.provider_error(redact_error(reason))], counter}
    end
  end

  defp build_event_from_map_type(type, map) do
    %Event{
      type: type,
      text: map_get(map, :text),
      tool_call: map_get(map, :tool_call),
      raw: map_get(map, :raw),
      usage: map_get(map, :usage),
      error: map_get(map, :error)
    }
  end

  # ---------------------------------------------------------------------------
  # Error path
  # ---------------------------------------------------------------------------

  defp handle_scripted_error(reason, emit) do
    redacted = redact_error(reason)
    emit.(Event.provider_error(redacted))
    {:error, redacted}
  end

  # Redact error data to ensure secrets never leak through the provider
  # error path.  Every term shape is covered — no fallback path returns
  # raw data without redaction.
  #
  #   • binaries  → EventPayloadRedactor.redact_string (secret pattern regex)
  #   • maps/lists → EventPayloadRedactor.redact + MetadataSanitizer.sanitize
  #   • tuples    → convert to list, redact, convert back
  #   • structs   → EventPayloadRedactor.redact handles struct preservation
  #   • atoms     → pass through (atoms never contain secret substrings)
  #   • numbers   → pass through
  #   • other     → inspect to string, then redact_string for secret patterns
  defp redact_error(reason) when is_binary(reason) do
    EventPayloadRedactor.redact_string(reason)
  end

  defp redact_error(%{__struct__: _} = reason) do
    # Structs (including exceptions) — must come before is_map clause since
    # structs are maps.  EventPayloadRedactor.redact preserves struct identity.
    reason
    |> EventPayloadRedactor.redact()
    |> MetadataSanitizer.sanitize()
  end

  defp redact_error(reason) when is_map(reason) do
    reason
    |> EventPayloadRedactor.redact()
    |> MetadataSanitizer.sanitize()
  end

  defp redact_error(reason) when is_list(reason) do
    reason
    |> EventPayloadRedactor.redact()
    |> MetadataSanitizer.sanitize()
  end

  defp redact_error(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> EventPayloadRedactor.redact()
    |> MetadataSanitizer.sanitize()
    |> List.to_tuple()
  end

  # Structs already handled above (before is_map clause)

  defp redact_error(reason) when is_atom(reason), do: reason

  defp redact_error(reason) when is_number(reason), do: reason

  defp redact_error(reason) do
    # Catch-all: inspect to string, then apply secret-pattern redaction.
    # This covers pids, refs, functions, and any other exotic terms.
    reason
    |> inspect(limit: 10, printable_limit: 500)
    |> EventPayloadRedactor.redact_string()
  end

  # ---------------------------------------------------------------------------
  # complete/2 script path — reuses normalize + accumulate, no emit
  # ---------------------------------------------------------------------------

  defp complete_from_script(script) when is_list(script) do
    initial_acc = %{
      deltas: [],
      completed_text: nil,
      tool_calls: [],
      usage: nil,
      counter: 0,
      error: nil
    }

    result =
      Enum.reduce_while(script, initial_acc, fn entry, acc ->
        {events, next_counter} = normalize_script_entry(entry, acc.counter)

        # Accumulate state (no emitting for complete/2)
        new_acc = accumulate_events(events || [], %{acc | counter: next_counter})

        # If an error was encountered, halt — same semantics as stream/2
        if new_acc.error != nil do
          {:halt, new_acc}
        else
          {:cont, new_acc}
        end
      end)

    if result.error != nil do
      {:error, result.error}
    else
      {:ok, build_response_from_acc(result)}
    end
  end

  defp complete_from_script(_other) do
    {:error, redact_error("fake_events must be a list")}
  end
end
