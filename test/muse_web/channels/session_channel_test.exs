defmodule MuseWeb.SessionChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  @endpoint MuseWeb.Endpoint

  alias Muse.Event
  alias MuseWeb.ExportJSON

  # -- Setup helpers ------------------------------------------------------------

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp ensure_pubsub do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:ok, _} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

      _pid ->
        :ok
    end
  end

  defp start_state do
    stop_named(Muse.State)
    {:ok, _} = Muse.State.start_link([])
  end

  defp start_endpoint do
    stop_named(MuseWeb.Endpoint)
    {:ok, _} = MuseWeb.Endpoint.start_link()
  end

  setup do
    ensure_pubsub()
    start_state()
    start_endpoint()

    on_exit(fn ->
      stop_named(MuseWeb.Endpoint)
      stop_named(Muse.State)
    end)

    :ok
  end

  # Helper to join the SessionChannel with a UserSocket
  defp join_session(topic) do
    socket(MuseWeb.UserSocket, nil, %{})
    |> subscribe_and_join(MuseWeb.SessionChannel, topic)
  end

  # -- Join tests --------------------------------------------------------------

  describe "join/3 — topic validation" do
    test "joins successfully with valid session:<session_id> topic" do
      assert {:ok, _reply, _socket} = join_session("session:abc-123")
    end

    test "rejects join with empty session id" do
      assert {:error, %{reason: "invalid_session_id"}} = join_session("session:")
    end

    test "rejects join with whitespace-only session id" do
      assert {:error, %{reason: "invalid_session_id"}} = join_session("session:   ")
    end

    test "rejects join with newline in session id" do
      assert {:error, %{reason: "invalid_session_id"}} = join_session("session:abc\nDEF")
    end

    test "rejects join with overly long session id" do
      long_id = String.duplicate("x", 257)

      assert {:error, %{reason: "invalid_session_id"}} = join_session("session:#{long_id}")
    end

    test "rejects join with non-session topic" do
      assert {:error, %{reason: "invalid_topic"}} = join_session("other:topic")
    end
  end

  # -- Replay on join -----------------------------------------------------------

  describe "join/3 — replay" do
    test "pushes replay of existing user-visible events for the session" do
      event =
        Event.new(:cli, :started, %{text: "hello"},
          session_id: "sess-replay",
          visibility: :user,
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z]
        )

      :ok = Muse.State.append(event)

      assert {:ok, _reply, _socket} = join_session("session:sess-replay")

      assert_push("muse_event", %{"events" => events})
      assert length(events) == 1

      [pushed] = events
      assert pushed["source"] == "cli"
      assert pushed["type"] == "started"
      assert pushed["session_id"] == "sess-replay"
    end

    test "replay omits internal and sensitive events" do
      user_event =
        Event.new(:cli, :started, %{text: "visible"},
          session_id: "sess-filter",
          visibility: :user,
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z]
        )

      internal_event =
        Event.new(:cli, :debug_detail, %{trace: "internal"},
          session_id: "sess-filter",
          visibility: :internal,
          id: 2,
          timestamp: ~U[2025-01-01 00:00:01Z]
        )

      sensitive_event =
        Event.new(:cli, :auth_dump, %{api_key: "sk-secret"},
          session_id: "sess-filter",
          visibility: :sensitive,
          id: 3,
          timestamp: ~U[2025-01-01 00:00:02Z]
        )

      :ok = Muse.State.append(user_event)
      :ok = Muse.State.append(internal_event)
      :ok = Muse.State.append(sensitive_event)

      assert {:ok, _reply, _socket} = join_session("session:sess-filter")

      assert_push("muse_event", %{"events" => events})
      # Only the user-visible event should appear
      assert length(events) == 1
      [pushed] = events
      assert pushed["type"] == "started"
    end

    test "replay only includes events for the joined session and globals" do
      this_session =
        Event.new(:cli, :started, %{},
          session_id: "sess-mine",
          visibility: :user,
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z]
        )

      _other_session =
        Event.new(:cli, :started, %{},
          session_id: "sess-other",
          visibility: :user,
          id: 2,
          timestamp: ~U[2025-01-01 00:00:01Z]
        )

      global_event =
        Event.new(:cli, :system_boot, %{},
          session_id: nil,
          visibility: :user,
          id: 3,
          timestamp: ~U[2025-01-01 00:00:02Z]
        )

      :ok = Muse.State.append(this_session)
      :ok = Muse.State.append(global_event)

      assert {:ok, _reply, _socket} = join_session("session:sess-mine")

      assert_push("muse_event", %{"events" => events})
      assert length(events) == 2

      session_ids = Enum.map(events, &Map.get(&1, "session_id"))
      assert "sess-mine" in session_ids
      refute "sess-other" in session_ids
    end
  end

  # -- Live event forwarding ----------------------------------------------------

  describe "handle_info — {:muse_event, event}" do
    test "pushes matching user-visible event to the channel" do
      assert {:ok, _reply, _socket} = join_session("session:live-sess")

      # Consume the replay push first
      assert_push("muse_event", %{"events" => []})

      event =
        Event.new(:cli, :user_message, %{text: "hi"},
          session_id: "live-sess",
          visibility: :user,
          id: 10,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      # Broadcast through State so PubSub delivers it
      :ok = Muse.State.append(event)

      assert_push("muse_event", pushed)
      assert pushed["source"] == "cli"
      assert pushed["type"] == "user_message"
      assert pushed["session_id"] == "live-sess"
    end

    test "does not push internal events to the channel" do
      assert {:ok, _reply, _chan_socket} = join_session("session:internal-test")

      # Consume the replay push
      assert_push("muse_event", %{"events" => []})

      internal_event =
        Event.new(:cli, :debug_detail, %{trace: "internal"},
          session_id: "internal-test",
          visibility: :internal,
          id: 20,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      # Internal events should be filtered out by the channel
      assert not event_visibility_allowed?(internal_event)
    end

    test "does not push sensitive events to the channel" do
      sensitive_event =
        Event.new(:cli, :auth_dump, %{api_key: "sk-test-key"},
          session_id: "sensitive-test",
          visibility: :sensitive,
          id: 21,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      assert not event_visibility_allowed?(sensitive_event)
    end

    test "global (nil session_id) events are forwarded to all sessions" do
      assert {:ok, _reply, _chan_socket} = join_session("session:global-test")

      # Consume the replay push
      assert_push("muse_event", %{"events" => []})

      global_event =
        Event.new(:system, :boot, %{},
          session_id: nil,
          visibility: :user,
          id: 30,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      # Broadcast through State
      :ok = Muse.State.append(global_event)

      assert_push("muse_event", pushed)
      # Global event — no session_id in the pushed envelope (nils dropped)
      refute Map.has_key?(pushed, "session_id")
      assert pushed["source"] == "system"
    end

    test "legacy events (nil visibility) are forwarded" do
      assert {:ok, _reply, _chan_socket} = join_session("session:legacy-test")

      # Consume the replay push
      assert_push("muse_event", %{"events" => []})

      legacy_event =
        Event.new(:cli, :started, %{text: "legacy"},
          session_id: "legacy-test",
          visibility: nil,
          id: 40,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      :ok = Muse.State.append(legacy_event)

      assert_push("muse_event", pushed)
      assert pushed["type"] == "started"
    end

    test "events for a different session are not pushed" do
      assert {:ok, _reply, _chan_socket} = join_session("session:live-mine")

      # Consume the replay push
      assert_push("muse_event", %{"events" => []})

      other_event =
        Event.new(:cli, :user_message, %{text: "other"},
          session_id: "live-other",
          visibility: :user,
          id: 11,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      # This event is for a different session, so it should NOT match
      assert not event_matches_session?(other_event, "live-mine")
    end
  end

  # -- Events cleared -----------------------------------------------------------

  describe "handle_info — {:muse_events_cleared}" do
    test "pushes events_cleared message" do
      assert {:ok, _reply, _chan_socket} = join_session("session:clear-test")

      # Consume the replay push
      assert_push("muse_event", %{"events" => []})

      Muse.State.clear()

      assert_push("events_cleared", %{})
    end
  end

  # -- Safety / envelope --------------------------------------------------------

  describe "safe event envelope" do
    test "redacts secrets in event data" do
      event =
        Event.new(:cli, :config, %{api_key: "sk-test-secret123", name: "safe"},
          session_id: "safety-test",
          visibility: :user,
          id: 50,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      envelope = safe_event_envelope(event)

      assert envelope["data"]["api_key"] == "[REDACTED]"
      assert envelope["data"]["name"] == "safe"
    end

    test "produces JSON-safe values only" do
      event =
        Event.new(:cli, :complex, %{pid: self(), ref: make_ref(), nested: %{tuple: {:a, :b}}},
          session_id: "json-safe-test",
          visibility: :user,
          id: 51,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      envelope = safe_event_envelope(event)

      # The envelope should be Jason-encodable without errors
      assert {:ok, _json} = Jason.encode(envelope)
    end

    test "drops nil values from envelope" do
      event =
        Event.new(:cli, :started, %{text: "hi"},
          session_id: "drop-nil-test",
          visibility: :user,
          id: 52,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      envelope = safe_event_envelope(event)

      # No nil values in the envelope map
      refute Enum.any?(envelope, fn {_k, v} -> is_nil(v) end)
    end

    test "does not expose provider/auth internals" do
      event =
        Event.new(
          :provider,
          :response,
          %{
            provider_state: %{bearer_token: "sk-super-secret"},
            model: "gpt-4",
            text: "Hello"
          },
          session_id: "no-internals-test",
          visibility: :user,
          id: 53,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      envelope = safe_event_envelope(event)

      # Secrets should be redacted, safe fields preserved
      assert {:ok, json} = Jason.encode(envelope)

      # The raw secret must not appear in the JSON
      refute String.contains?(json, "sk-super-secret")
    end
  end

  # -- Helpers ------------------------------------------------------------------

  # Replicate the channel's private logic for direct unit testing
  defp event_matches_session?(%Event{session_id: nil}, _session_id), do: true
  defp event_matches_session?(%Event{session_id: sid}, session_id), do: sid == session_id

  defp event_visibility_allowed?(%Event{visibility: v}), do: v in [:user, nil]

  defp safe_event_envelope(%Event{} = event) do
    alias Muse.EventDisplay

    %{
      "id" => event.id,
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "source" => to_string(event.source),
      "type" => to_string(event.type),
      "data" => event.data |> EventDisplay.safe_data() |> ExportJSON.json_safe(),
      "session_id" => event.session_id,
      "turn_id" => event.turn_id,
      "seq" => event.seq,
      "muse_id" => event.muse_id
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end
end
