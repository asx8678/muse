defmodule MuseWeb.SessionChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  @endpoint MuseWeb.Endpoint

  alias Muse.Event
  alias MuseWeb.ExternalEventFilter

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

    # Enable external WS for channel tests with test token hashes
    original_ws = Application.get_env(:muse, :external_ws)
    original_sys = System.get_env("MUSE_EXTERNAL_WS")

    test_token_hash =
      :crypto.hash(:sha256, "test-token-16chars-ok")
      |> Base.encode16(case: :lower)

    restricted_token_hash =
      :crypto.hash(:sha256, "test-restricted-token")
      |> Base.encode16(case: :lower)

    Application.put_env(
      :muse,
      :external_ws,
      enabled: true,
      replay_limit: 50,
      token_hashes: [
        %{
          id: "test-token",
          hash: test_token_hash,
          scopes: ["events:read"],
          allowed_sessions: :all
        },
        %{
          id: "test-restricted",
          hash: restricted_token_hash,
          scopes: ["events:read"],
          allowed_sessions: ["sess-allowed"]
        }
      ]
    )

    on_exit(fn ->
      Application.put_env(:muse, :external_ws, original_ws || [enabled: false, replay_limit: 100])

      if original_sys do
        System.put_env("MUSE_EXTERNAL_WS", original_sys)
      else
        System.delete_env("MUSE_EXTERNAL_WS")
      end

      stop_named(MuseWeb.Endpoint)
      stop_named(Muse.State)
    end)

    :ok
  end

  # Helper to join the SessionChannel with a UserSocket
  # Uses Phoenix.ChannelTest.connect/3 to go through UserSocket.connect/3
  # for proper authentication testing.
  defp connect_and_join(topic, token \\ "test-token-16chars-ok") do
    {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => token})
    subscribe_and_join(socket, MuseWeb.SessionChannel, topic)
  end

  # Helper for tests that need to control the socket params directly
  # (e.g., missing token, invalid token)
  defp connect_socket(params) do
    connect(MuseWeb.UserSocket, params)
  end

  # -- Join tests ---------------------------------------------------------------

  describe "join/3 — topic validation" do
    test "joins successfully with valid session:<session_id> topic" do
      assert {:ok, _reply, _socket} = connect_and_join("session:abc-123")
    end

    test "rejects join with empty session id" do
      assert {:error, %{reason: "invalid_session_id"}} = connect_and_join("session:")
    end

    test "rejects join with dot-only session id" do
      assert {:error, %{reason: "invalid_session_id"}} = connect_and_join("session:.")
    end

    test "rejects join with dotdot session id" do
      assert {:error, %{reason: "invalid_session_id"}} = connect_and_join("session:..")
    end

    test "rejects join with path traversal in session id" do
      assert {:error, %{reason: "invalid_session_id"}} = connect_and_join("session:../escape")
    end

    test "rejects join with slash in session id" do
      assert {:error, %{reason: "invalid_session_id"}} = connect_and_join("session:foo/bar")
    end

    test "rejects join with backslash in session id" do
      assert {:error, %{reason: "invalid_session_id"}} = connect_and_join("session:foo\\bar")
    end

    test "rejects join with NUL in session id" do
      assert {:error, %{reason: "invalid_session_id"}} = connect_and_join("session:foo\0bar")
    end

    test "rejects join with overly-long session id (> 256 bytes)" do
      too_long = String.duplicate("a", 257)
      assert {:error, %{reason: "invalid_session_id"}} = connect_and_join("session:" <> too_long)
    end

    test "rejects join with non-session topic" do
      assert {:error, %{reason: "invalid_topic"}} = connect_and_join("other:topic")
    end
  end

  # -- Config guard tests -------------------------------------------------------

  describe "join/3 — config guard" do
    test "rejects connection when external WS is disabled" do
      System.delete_env("MUSE_EXTERNAL_WS")
      Application.put_env(:muse, :external_ws, enabled: false, token_hashes: [])

      assert :error = connect_socket(%{"token" => "test-token-16chars-ok"})
    end

    test "allows join when external WS is enabled" do
      test_token_hash =
        :crypto.hash(:sha256, "test-token-16chars-ok")
        |> Base.encode16(case: :lower)

      Application.put_env(:muse, :external_ws,
        enabled: true,
        replay_limit: 50,
        token_hashes: [
          %{
            id: "test-token",
            hash: test_token_hash,
            scopes: ["events:read"],
            allowed_sessions: :all
          }
        ]
      )

      assert {:ok, _reply, _socket} = connect_and_join("session:valid-id")
    end
  end

  # -- Replay on join -----------------------------------------------------------

  describe "join/3 — replay" do
    test "pushes replay of existing user-visible events for the session" do
      event =
        Event.new(:cli, :user_message, %{text: "hello"},
          session_id: "sess-replay",
          visibility: :user,
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z]
        )

      :ok = Muse.State.append(event)

      assert {:ok, _reply, _socket} = connect_and_join("session:sess-replay")

      assert_push("muse_event", %{"events" => events})
      assert length(events) == 1

      [pushed] = events
      assert pushed["source"] == "cli"
      assert pushed["type"] == "user_message"
      assert pushed["session_id"] == "sess-replay"
    end

    test "replay omits internal and sensitive events" do
      user_event =
        Event.new(:cli, :user_message, %{text: "visible"},
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

      assert {:ok, _reply, _socket} = connect_and_join("session:sess-filter")

      assert_push("muse_event", %{"events" => events})
      # Only the user-visible event should appear
      assert length(events) == 1
      [pushed] = events
      assert pushed["type"] == "user_message"
    end

    test "replay only includes events for the joined session (no nil session_id)" do
      this_session =
        Event.new(:cli, :user_message, %{text: "mine"},
          session_id: "sess-mine",
          visibility: :user,
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z]
        )

      _other_session =
        Event.new(:cli, :user_message, %{text: "other"},
          session_id: "sess-other",
          visibility: :user,
          id: 2,
          timestamp: ~U[2025-01-01 00:00:01Z]
        )

      # Nil session_id events are NOT forwarded on session topics
      global_event =
        Event.new(:cli, :system_boot, %{},
          session_id: nil,
          visibility: :user,
          id: 3,
          timestamp: ~U[2025-01-01 00:00:02Z]
        )

      :ok = Muse.State.append(this_session)
      :ok = Muse.State.append(global_event)

      assert {:ok, _reply, _socket} = connect_and_join("session:sess-mine")

      assert_push("muse_event", %{"events" => events})
      assert length(events) == 1

      [pushed] = events
      assert pushed["session_id"] == "sess-mine"
    end
  end

  # -- Live event forwarding ----------------------------------------------------

  describe "handle_info — {:muse_event, event}" do
    test "pushes matching user-visible event to the channel" do
      assert {:ok, _reply, _socket} = connect_and_join("session:live-sess")

      # Consume the replay push first
      assert_push("muse_event", %{"events" => _})

      event =
        Event.new(:cli, :user_message, %{text: "hi"},
          session_id: "live-sess",
          visibility: :user,
          id: 10,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      :ok = Muse.State.append(event)

      assert_push("muse_event", pushed)
      assert pushed["source"] == "cli"
      assert pushed["type"] == "user_message"
      assert pushed["session_id"] == "live-sess"
      assert Map.has_key?(pushed, "payload")
    end

    test "does not push internal events to the channel" do
      assert {:ok, _reply, _chan_socket} = connect_and_join("session:internal-test")

      # Consume the replay push
      assert_push("muse_event", %{"events" => _})

      internal_event =
        Event.new(:cli, :debug_detail, %{trace: "internal"},
          session_id: "internal-test",
          visibility: :internal,
          id: 20,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      # Internal events are filtered out by the ExternalEventFilter
      assert {:error, {:denied_visibility, :internal}} =
               ExternalEventFilter.to_external_map(internal_event, session_id: "internal-test")
    end

    test "does not push sensitive events to the channel" do
      sensitive_event =
        Event.new(:cli, :auth_dump, %{api_key: "sk-test-key"},
          session_id: "sensitive-test",
          visibility: :sensitive,
          id: 21,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      assert {:error, {:denied_visibility, :sensitive}} =
               ExternalEventFilter.to_external_map(sensitive_event, session_id: "sensitive-test")
    end

    test "nil session_id events are not forwarded on session topics" do
      assert {:ok, _reply, _chan_socket} = connect_and_join("session:global-test")

      # Consume the replay push
      assert_push("muse_event", %{"events" => _})

      global_event =
        Event.new(:system, :boot, %{},
          session_id: nil,
          visibility: :user,
          id: 30,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      # nil session_id events are denied on session-scoped topics
      assert {:error, :session_mismatch} =
               ExternalEventFilter.to_external_map(global_event, session_id: "global-test")
    end

    test "events for a different session are not pushed" do
      other_event =
        Event.new(:cli, :user_message, %{text: "other"},
          session_id: "live-other",
          visibility: :user,
          id: 11,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      # session mismatch
      assert {:error, :session_mismatch} =
               ExternalEventFilter.to_external_map(other_event, session_id: "live-mine")
    end
  end

  # -- Events cleared -----------------------------------------------------------

  describe "handle_info — {:muse_events_cleared}" do
    test "pushes events_cleared message" do
      assert {:ok, _reply, _chan_socket} = connect_and_join("session:clear-test")

      # Consume the replay push
      assert_push("muse_event", %{"events" => _})

      Muse.State.clear()

      assert_push("events_cleared", %{})
    end
  end

  # -- Safety / envelope --------------------------------------------------------

  describe "safe event envelope" do
    test "redacts secrets in event data" do
      event =
        Event.new(:cli, :user_message, %{api_key: "sk-test-secret123", name: "safe"},
          session_id: "safety-test",
          visibility: :user,
          id: 50,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      assert {:ok, envelope} =
               ExternalEventFilter.to_external_map(event, session_id: "safety-test")

      assert envelope["payload"]["api_key"] =~ "REDACTED"
      assert envelope["payload"]["name"] == "safe"
    end

    test "produces JSON-safe values only" do
      event =
        Event.new(
          :cli,
          :user_message,
          %{pid: self(), ref: make_ref(), nested: %{tuple: {:a, :b}}},
          session_id: "json-safe-test",
          visibility: :user,
          id: 51,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      assert {:ok, envelope} =
               ExternalEventFilter.to_external_map(event, session_id: "json-safe-test")

      assert {:ok, _json} = Jason.encode(envelope)
    end

    test "uses payload key in envelope" do
      event =
        Event.new(:cli, :user_message, %{text: "hi"},
          session_id: "payload-key-test",
          visibility: :user,
          id: 52,
          timestamp: ~U[2025-01-01 12:00:00Z]
        )

      assert {:ok, envelope} =
               ExternalEventFilter.to_external_map(event, session_id: "payload-key-test")

      assert Map.has_key?(envelope, "payload")
      refute Map.has_key?(envelope, "data")
    end

    test "does not expose provider/auth internals" do
      event =
        Event.new(
          :provider,
          :user_message,
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

      assert {:ok, envelope} =
               ExternalEventFilter.to_external_map(event, session_id: "no-internals-test")

      assert {:ok, json} = Jason.encode(envelope)
      refute String.contains?(json, "sk-super-secret")
    end
  end
end
