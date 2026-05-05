defmodule MuseWeb.SessionChannelTest do
  use MuseWeb.ChannelCase, async: false

  alias Muse.{Event, State}

  describe "socket connection" do
    test "socket /socket can connect via UserSocket" do
      assert {:ok, socket} = connect(MuseWeb.UserSocket, %{})
      assert socket
    end
  end

  describe "join session:<id>" do
    setup do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{})
      %{socket: socket}
    end

    test "succeeds for a valid session id", %{socket: socket} do
      assert {:ok, _reply, channel_socket} =
               subscribe_and_join(socket, "session:sess_12345")

      assert channel_socket.assigns.session_id == "sess_12345"
    end

    test "succeeds for session id with hyphens and underscores", %{socket: socket} do
      assert {:ok, _reply, channel_socket} =
               subscribe_and_join(socket, "session:sess-abc_def-123")

      assert channel_socket.assigns.session_id == "sess-abc_def-123"
    end

    test "rejects topic 'foo'", %{socket: socket} do
      assert_raise RuntimeError, ~r/no channel found for topic "foo"/, fn ->
        subscribe_and_join(socket, "foo")
      end
    end

    test "rejects topic 'session:' (empty id)", %{socket: socket} do
      assert {:error, %{reason: :invalid_session_id}} =
               subscribe_and_join(socket, "session:")
    end

    test "rejects session id with path traversal (slash)", %{socket: socket} do
      assert {:error, %{reason: :invalid_session_id}} =
               subscribe_and_join(socket, "session:../../x")
    end

    test "rejects session id with backslash", %{socket: socket} do
      assert {:error, %{reason: :invalid_session_id}} =
               subscribe_and_join(socket, "session:..\\..\\x")
    end

    test "rejects session id '.'", %{socket: socket} do
      assert {:error, %{reason: :invalid_session_id}} =
               subscribe_and_join(socket, "session:.")
    end

    test "rejects session id '..'", %{socket: socket} do
      assert {:error, %{reason: :invalid_session_id}} =
               subscribe_and_join(socket, "session:..")
    end
  end

  describe "replay delivers only matching events" do
    setup do
      # Seed State with events for multiple sessions
      State.clear()

      State.append(
        Event.new(:test, :message, %{text: "hello"},
          id: 100,
          session_id: "sess_1",
          visibility: :user
        )
      )

      State.append(
        Event.new(:test, :message, %{text: "world"},
          id: 101,
          session_id: "sess_2",
          visibility: :user
        )
      )

      State.append(
        Event.new(:test, :debug_info, %{detail: "trace"},
          id: 102,
          session_id: "sess_1",
          visibility: :debug
        )
      )

      :ok
    end

    test "replays only events matching the session on join", %{} do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{})

      assert {:ok, _reply, _channel_socket} =
               subscribe_and_join(socket, "session:sess_1")

      # We should receive the sess_1 :user event
      assert_push("muse_event", %{id: 100, source: :test, type: :message, data: %{text: "hello"}})

      # We should receive the sess_1 :debug event (debug is visible)
      assert_push("muse_event", %{
        id: 102,
        source: :test,
        type: :debug_info,
        data: %{detail: "trace"}
      })

      # We should NOT receive the sess_2 event
      refute_received {:muse_event, %{id: 101}}
    end

    test "replays no events for session with no matching events", %{} do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{})

      assert {:ok, _reply, _channel_socket} =
               subscribe_and_join(socket, "session:sess_empty")

      # Should not receive any muse_event (allow a short window for replay)
      refute_receive {:muse_event, _}, 100
    end
  end

  describe "live State.append broadcasts" do
    setup do
      State.clear()
      {:ok, socket} = connect(MuseWeb.UserSocket, %{})

      assert {:ok, _reply, channel_socket} =
               subscribe_and_join(socket, "session:sess_live")

      %{channel_socket: channel_socket}
    end

    test "forwards events matching the session", %{channel_socket: _cs} do
      State.append(
        Event.new(:test, :live_event, %{msg: "live!"},
          id: 200,
          session_id: "sess_live",
          visibility: :user
        )
      )

      assert_push("muse_event", %{
        id: 200,
        source: :test,
        type: :live_event,
        data: %{msg: "live!"}
      })
    end

    test "does not forward events for a different session", %{channel_socket: _cs} do
      State.append(
        Event.new(:test, :other, %{msg: "other"},
          id: 201,
          session_id: "sess_other",
          visibility: :user
        )
      )

      refute_receive {:muse_event, %{id: 201}}, 200
    end
  end

  describe "visibility filtering" do
    setup do
      State.clear()
      {:ok, socket} = connect(MuseWeb.UserSocket, %{})

      assert {:ok, _reply, channel_socket} =
               subscribe_and_join(socket, "session:sess_vis")

      %{channel_socket: channel_socket}
    end

    test ":internal events are never pushed", %{channel_socket: _cs} do
      State.append(
        Event.new(:test, :internal_event, %{secret: "internal"},
          id: 300,
          session_id: "sess_vis",
          visibility: :internal
        )
      )

      refute_receive {:muse_event, %{id: 300}}, 200
    end

    test ":sensitive events are never pushed", %{channel_socket: _cs} do
      State.append(
        Event.new(:test, :sensitive_event, %{secret: "sensitive"},
          id: 301,
          session_id: "sess_vis",
          visibility: :sensitive
        )
      )

      refute_receive {:muse_event, %{id: 301}}, 200
    end

    test ":user events are pushed", %{channel_socket: _cs} do
      State.append(
        Event.new(:test, :user_event, %{msg: "hello"},
          id: 302,
          session_id: "sess_vis",
          visibility: :user
        )
      )

      assert_push("muse_event", %{id: 302, visibility: :user})
    end

    test ":debug events are pushed", %{channel_socket: _cs} do
      State.append(
        Event.new(:test, :debug_event, %{detail: "trace"},
          id: 303,
          session_id: "sess_vis",
          visibility: :debug
        )
      )

      assert_push("muse_event", %{id: 303, visibility: :debug})
    end

    test "nil-visibility events are pushed (default to visible)", %{channel_socket: _cs} do
      State.append(Event.new(:test, :bare_event, %{msg: "bare"}, id: 304, session_id: "sess_vis"))

      assert_push("muse_event", %{id: 304})
    end

    test ":internal events are also filtered during replay", %{} do
      State.clear()

      State.append(
        Event.new(:test, :internal_replay, %{data: "hidden"},
          id: 310,
          session_id: "sess_replay_vis",
          visibility: :internal
        )
      )

      State.append(
        Event.new(:test, :user_replay, %{data: "visible"},
          id: 311,
          session_id: "sess_replay_vis",
          visibility: :user
        )
      )

      {:ok, socket} = connect(MuseWeb.UserSocket, %{})

      assert {:ok, _reply, _channel_socket} =
               subscribe_and_join(socket, "session:sess_replay_vis")

      # Only user-visible event should arrive
      assert_push("muse_event", %{id: 311, data: %{data: "visible"}})
      refute_receive {:muse_event, %{id: 310}}, 100
    end
  end

  describe "payload redaction" do
    setup do
      State.clear()
      {:ok, socket} = connect(MuseWeb.UserSocket, %{})

      assert {:ok, _reply, channel_socket} =
               subscribe_and_join(socket, "session:sess_redact")

      %{channel_socket: channel_socket}
    end

    test "secret patterns in payload data are redacted", %{channel_socket: _cs} do
      State.append(
        Event.new(:test, :msg_with_secret, %{text: "my key is sk-test-abc123"},
          id: 400,
          session_id: "sess_redact",
          visibility: :user
        )
      )

      assert_push("muse_event", %{id: 400, data: %{text: "my key is [REDACTED]"}})
    end

    test "sensitive keys in payload are redacted", %{channel_socket: _cs} do
      State.append(
        Event.new(:test, :auth_event, %{api_key: "secret-value"},
          id: 401,
          session_id: "sess_redact",
          visibility: :user
        )
      )

      assert_push("muse_event", %{id: 401, data: %{api_key: "[REDACTED]"}})
    end

    test "payload is JSON-safe (serializable)", %{channel_socket: _cs} do
      State.append(
        Event.new(:test, :struct_data, %{nested: %{key: :atom_value, list: [1, 2, 3]}},
          id: 402,
          session_id: "sess_redact",
          visibility: :user
        )
      )

      assert_push("muse_event", %{id: 402, data: %{nested: %{key: :atom_value, list: [1, 2, 3]}}})
    end
  end

  describe "LiveView route unaffected" do
    test "existing LiveView socket still works" do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      ensure_pubsub()

      {:ok, lv, _html} = live(build_conn(), "/")
      assert render(lv)
    end
  end
end
