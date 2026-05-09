defmodule Muse.Test.EventFixtures do
  @moduledoc """
  Reusable helpers for building synthetic events and event streams.

  These helpers produce deterministic `%Muse.Event{}` structs suitable for
  testing `EventStream.chat_messages/1`, `EventStream.external_replay/2`,
  and other event-consuming code without relying on live providers or
  real sessions.

  All events use pinned IDs, timestamps, and sequential `seq` values so
  tests are fully deterministic and offline.

  ## Usage

      alias Muse.Test.EventFixtures, as: EF

      events = EF.chat_turn("t1", "hello", "world")
      messages = Muse.EventStream.chat_messages(events)
  """

  alias Muse.Event

  @fixed_time ~U[2025-01-15 12:00:00Z]

  @doc "Returns the fixed timestamp used by all fixture helpers."
  @spec fixed_time :: DateTime.t()
  def fixed_time, do: @fixed_time

  @doc "Increment the fixed time by `n` seconds (for ordering distinct events)."
  @spec time_after(integer()) :: DateTime.t()
  def time_after(n) when is_integer(n) do
    DateTime.add(@fixed_time, n, :second)
  end

  # ---------------------------------------------------------------------------
  # Single-event builders
  # ---------------------------------------------------------------------------

  @doc "Build a `:user_message` event."
  @spec user_message(String.t(), keyword()) :: Event.t()
  def user_message(text, opts \\ []) do
    Event.new(
      Keyword.get(opts, :source, :test),
      :user_message,
      %{text: text},
      merge_defaults(opts)
    )
  end

  @doc "Build an `:assistant_delta` event."
  @spec assistant_delta(String.t(), keyword()) :: Event.t()
  def assistant_delta(text, opts \\ []) do
    Event.new(
      Keyword.get(opts, :source, :test),
      :assistant_delta,
      %{text: text},
      merge_defaults(opts)
    )
  end

  @doc "Build an `:assistant_message` (final) event."
  @spec assistant_message(String.t(), keyword()) :: Event.t()
  def assistant_message(text, opts \\ []) do
    streamed? = Keyword.get(opts, :streamed?, false)
    data = %{text: text, streamed?: streamed?}

    Event.new(
      Keyword.get(opts, :source, :test),
      :assistant_message,
      data,
      merge_defaults(opts)
    )
  end

  @doc "Build a `:plan_created` system event."
  @spec plan_created(String.t(), keyword()) :: Event.t()
  def plan_created(plan_id, opts \\ []) do
    Event.new(
      Keyword.get(opts, :source, :test),
      :plan_created,
      %{plan_id: plan_id, objective: Keyword.get(opts, :objective, "test plan")},
      merge_defaults(opts)
    )
  end

  @doc "Build a `:patch_proposed` system event."
  @spec patch_proposed(String.t(), keyword()) :: Event.t()
  def patch_proposed(patch_id, opts \\ []) do
    Event.new(
      Keyword.get(opts, :source, :test),
      :patch_proposed,
      %{
        patch_id: patch_id,
        files: Keyword.get(opts, :files, ["lib/a.ex"]),
        hash: Keyword.get(opts, :hash, "abc123"),
        diff: Keyword.get(opts, :diff, "short diff")
      },
      merge_defaults(opts)
    )
  end

  @doc "Build an event with arbitrary type and data."
  @spec event(atom(), term(), keyword()) :: Event.t()
  def event(type, data, opts \\ []) do
    Event.new(
      Keyword.get(opts, :source, :test),
      type,
      data,
      merge_defaults(opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Composite builders — produce lists of related events
  # ---------------------------------------------------------------------------

  @doc """
  Build a complete chat turn: user message + assistant final message.

  Returns a list of two events with sequential IDs and seq values.
  """
  @spec chat_turn(String.t(), String.t(), String.t(), keyword()) :: [Event.t()]
  def chat_turn(turn_id, user_text, assistant_text, opts \\ []) do
    base_id = Keyword.get(opts, :base_id, 1)

    [
      user_message(user_text,
        id: base_id,
        turn_id: turn_id,
        seq: 1,
        session_id: Keyword.get(opts, :session_id, "sess_1"),
        visibility: :user,
        timestamp: time_after(0)
      ),
      assistant_message(assistant_text,
        id: base_id + 1,
        turn_id: turn_id,
        seq: 2,
        session_id: Keyword.get(opts, :session_id, "sess_1"),
        visibility: :user,
        timestamp: time_after(1)
      )
    ]
  end

  @doc """
  Build a streaming chat turn: user + deltas + streamed final.

  Returns a list of events simulating a streaming response.
  The `deltas` list is a list of `{text_chunk}` tuples or plain strings.
  """
  @spec streaming_turn(String.t(), String.t(), [String.t()], keyword()) :: [Event.t()]
  def streaming_turn(turn_id, user_text, delta_chunks, opts \\ []) do
    base_id = Keyword.get(opts, :base_id, 1)
    session_id = Keyword.get(opts, :session_id, "sess_1")
    full_text = Enum.join(delta_chunks)

    user_evt =
      user_message(user_text,
        id: base_id,
        turn_id: turn_id,
        seq: 1,
        session_id: session_id,
        visibility: :user,
        timestamp: time_after(0)
      )

    delta_events =
      delta_chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, i} ->
        assistant_delta(chunk,
          id: base_id + 1 + i,
          turn_id: turn_id,
          seq: 2 + i,
          session_id: session_id,
          visibility: :user,
          timestamp: time_after(1 + i)
        )
      end)

    delta_count = length(delta_chunks)

    final_evt =
      assistant_message(full_text,
        id: base_id + 1 + delta_count,
        turn_id: turn_id,
        seq: 2 + delta_count,
        session_id: session_id,
        visibility: :user,
        streamed?: true,
        timestamp: time_after(1 + delta_count)
      )

    [user_evt] ++ delta_events ++ [final_evt]
  end

  # ---------------------------------------------------------------------------
  # Bulk generators — for performance/baseline testing
  # ---------------------------------------------------------------------------

  @doc """
  Generate `n` simple chat turns with deterministic IDs.

  Each turn gets `turn_id` `"t_1"` through `"t_<n>"`.
  User messages say `"user <i>"` and assistant messages say `"assistant <i>"`.

  Returns a flat list of `2 * n` events.
  """
  @spec bulk_chat_turns(pos_integer(), keyword()) :: [Event.t()]
  def bulk_chat_turns(n, opts \\ []) when n > 0 do
    session_id = Keyword.get(opts, :session_id, "sess_1")

    for i <- 1..n, reduce: [] do
      acc ->
        turn_id = "t_#{i}"
        base_id = (i - 1) * 2 + 1

        turn =
          chat_turn(turn_id, "user #{i}", "assistant #{i}",
            base_id: base_id,
            session_id: session_id
          )

        acc ++ turn
    end
  end

  @doc """
  Generate `n` streaming chat turns, each with `chunks_per_turn` delta chunks.

  Returns a flat list with `(1 + chunks_per_turn + 1) * n` events.
  """
  @spec bulk_streaming_turns(pos_integer(), pos_integer(), keyword()) :: [Event.t()]
  def bulk_streaming_turns(n, chunks_per_turn, opts \\ []) when n > 0 and chunks_per_turn > 0 do
    session_id = Keyword.get(opts, :session_id, "sess_1")
    events_per_turn = 1 + chunks_per_turn + 1

    for i <- 1..n, reduce: [] do
      acc ->
        turn_id = "t_#{i}"
        base_id = (i - 1) * events_per_turn + 1
        chunks = for j <- 1..chunks_per_turn, do: "chunk_#{i}_#{j} "

        turn =
          streaming_turn(turn_id, "user #{i}", chunks,
            base_id: base_id,
            session_id: session_id
          )

        acc ++ turn
    end
  end

  @doc """
  Generate `n` events with `nil` `turn_id` (legacy-style events).

  These are useful for testing legacy event handling in `chat_messages/1`.
  """
  @spec bulk_legacy_events(pos_integer(), keyword()) :: [Event.t()]
  def bulk_legacy_events(n, opts \\ []) when n > 0 do
    for i <- 1..n do
      type = if rem(i, 2) == 1, do: :user_message, else: :assistant_message

      event(type, %{text: "legacy #{i}"},
        id: i,
        turn_id: nil,
        seq: nil,
        session_id: Keyword.get(opts, :session_id, "sess_1"),
        visibility: :user,
        timestamp: time_after(i)
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp merge_defaults(opts) do
    Keyword.merge(
      [session_id: "sess_1", visibility: :user, timestamp: @fixed_time],
      opts
    )
  end
end
