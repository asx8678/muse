defmodule MuseWeb.ExternalEventFilterTest do
  use ExUnit.Case, async: true

  alias MuseWeb.ExternalEventFilter
  alias Muse.Event

  # -- Helpers ------------------------------------------------------------------

  defp make_event(type, data, opts) do
    base = [
      id: System.unique_integer([:positive]),
      timestamp: ~U[2025-06-15 12:00:00Z]
    ]

    Event.new(:test, type, data, Keyword.merge(base, opts))
  end

  defp make_event(type, data), do: make_event(type, data, [])

  # -- Session filter tests -----------------------------------------------------

  describe "session filtering" do
    test "allows event when no session_id option is provided" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, session_id: "s1")
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows event when session_id option matches event session_id" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, session_id: "s1")
      assert {:ok, _} = ExternalEventFilter.filter(event, session_id: "s1")
    end

    test "denies event when session_id option does not match" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, session_id: "s1")

      assert {:error, :session_mismatch} =
               ExternalEventFilter.filter(event, session_id: "s_other")
    end

    test "denies event when session_id option is set but event session_id is nil" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user)
      assert {:error, :session_mismatch} = ExternalEventFilter.filter(event, session_id: "s1")
    end

    test "session mismatch takes priority over visibility check" do
      # Internal event that would also fail visibility, but session check runs first
      event = make_event(:internal_op, %{}, visibility: :internal, session_id: "s1")

      assert {:error, :session_mismatch} =
               ExternalEventFilter.filter(event, session_id: "s_wrong")
    end
  end

  # -- Visibility filter tests --------------------------------------------------

  describe "visibility filtering" do
    test "allows :user visibility events" do
      event = make_event(:user_message, %{text: "hello"}, visibility: :user)
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "denies :internal visibility events" do
      event = make_event(:internal_op, %{}, visibility: :internal)
      assert {:error, :visibility_denied} = ExternalEventFilter.filter(event, [])
    end

    test "denies :sensitive visibility events" do
      event = make_event(:secret_op, %{}, visibility: :sensitive)
      assert {:error, :visibility_denied} = ExternalEventFilter.filter(event, [])
    end

    test "denies :debug visibility events by default" do
      event = make_event(:debug_info, %{}, visibility: :debug)
      assert {:error, :visibility_denied} = ExternalEventFilter.filter(event, [])
    end

    test "allows :debug visibility events when allow_debug? is true" do
      event = make_event(:debug_info, %{}, visibility: :debug)
      assert {:ok, _} = ExternalEventFilter.filter(event, allow_debug?: true)
    end

    test "denies :debug visibility events when allow_debug? is false" do
      event = make_event(:debug_info, %{}, visibility: :debug)
      assert {:error, :visibility_denied} = ExternalEventFilter.filter(event, allow_debug?: false)
    end
  end

  # -- Nil visibility allowlist tests -------------------------------------------

  describe "nil visibility allowlist" do
    test "allows user_message with nil visibility" do
      event = make_event(:user_message, %{text: "hi"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows assistant_delta with nil visibility" do
      event = make_event(:assistant_delta, %{text: "chunk"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows assistant_message with nil visibility" do
      event = make_event(:assistant_message, %{text: "done"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows plan_created with nil visibility" do
      event = make_event(:plan_created, %{objective: "test"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows plan_approved with nil visibility" do
      event = make_event(:plan_approved, %{plan_id: "p1"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows plan_rejected with nil visibility" do
      event = make_event(:plan_rejected, %{plan_id: "p1"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows approval_requested with nil visibility" do
      event = make_event(:approval_requested, %{approval_id: "a1"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows approval_approved with nil visibility" do
      event = make_event(:approval_approved, %{approval_id: "a1"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows approval_rejected with nil visibility" do
      event = make_event(:approval_rejected, %{approval_id: "a1"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows turn_completed with nil visibility" do
      event = make_event(:turn_completed, %{})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows turn_failed with nil visibility" do
      event = make_event(:turn_failed, %{})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "allows session_status_changed with nil visibility" do
      event = make_event(:session_status_changed, %{status: "active"})
      assert {:ok, _} = ExternalEventFilter.filter(event, [])
    end

    test "denies unlisted type with nil visibility" do
      event = make_event(:some_internal_type, %{})
      assert {:error, :nil_visibility_type_not_allowed} = ExternalEventFilter.filter(event, [])
    end

    test "denies :reloaded type with nil visibility (not on allowlist)" do
      event = make_event(:reloaded, %{file: "lib/app.ex"})
      assert {:error, :nil_visibility_type_not_allowed} = ExternalEventFilter.filter(event, [])
    end

    test "denies :config_loaded type with nil visibility" do
      event = make_event(:config_loaded, %{})
      assert {:error, :nil_visibility_type_not_allowed} = ExternalEventFilter.filter(event, [])
    end
  end

  # -- Envelope structure tests -------------------------------------------------

  describe "envelope structure" do
    test "includes required string-key fields" do
      event =
        make_event(:user_message, %{text: "hi"},
          visibility: :user,
          session_id: "s1",
          turn_id: "t1",
          seq: 3
        )

      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      assert envelope["type"] == "user_message"
      assert envelope["source"] == "test"
      assert envelope["timestamp"] == "2025-06-15T12:00:00Z"
      assert envelope["session_id"] == "s1"
      assert envelope["turn_id"] == "t1"
      assert envelope["seq"] == 3
      assert envelope["visibility"] == "user"
      assert is_map(envelope["payload"])
    end

    test "omits nil optional fields" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      refute Map.has_key?(envelope, "session_id")
      refute Map.has_key?(envelope, "turn_id")
      refute Map.has_key?(envelope, "seq")
      # visibility is :user so it's present
      assert envelope["visibility"] == "user"
    end

    test "omits visibility key when event visibility is nil" do
      event = make_event(:user_message, %{text: "hi"})
      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      refute Map.has_key?(envelope, "visibility")
    end

    test "all keys are strings (Jason-safe)" do
      event = make_event(:assistant_delta, %{text: "chunk"}, visibility: :user, session_id: "s1")
      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      for key <- Map.keys(envelope) do
        assert is_binary(key), "Expected string key, got: #{inspect(key)}"
      end
    end

    test "envelope is encodable by Jason" do
      event = make_event(:user_message, %{text: "hello world"}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      assert {:ok, json} = Jason.encode(envelope)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["type"] == "user_message"
      assert decoded["payload"]["text"] == "hello world"
    end
  end

  # -- Payload redaction tests --------------------------------------------------

  describe "payload redaction" do
    test "redacts API-key-like payloads through EventDisplay.safe_data" do
      event = make_event(:user_message, %{text: "key is sk-test-12345"}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      refute envelope["payload"]["text"] =~ "sk-test-12345"
      assert envelope["payload"]["text"] =~ "[REDACTED]"
    end

    test "redacts Bearer token payloads" do
      event =
        make_event(
          :user_message,
          %{text: "Authorization: Bearer super-secret-token-xyz"},
          visibility: :user
        )

      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      refute envelope["payload"]["text"] =~ "super-secret-token-xyz"
    end

    test "redacts sensitive map keys (api_key, token, etc.)" do
      event =
        make_event(
          :assistant_delta,
          %{text: "response", api_key: "sk-proj-abcdef123456"},
          visibility: :user
        )

      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      # api_key value should be redacted
      assert envelope["payload"]["api_key"] =~ "REDACTED"
      refute envelope["payload"]["api_key"] =~ "sk-proj"
      # text should still be present
      assert envelope["payload"]["text"] == "response"
    end

    test "omits raw plan JSON through EventDisplay.safe_data" do
      raw_plan_json =
        Jason.encode!(%{
          objective: "Take over the world",
          tasks: [%{id: 1, title: "Build lair"}]
        })

      event = make_event(:plan_created, %{raw_json: raw_plan_json}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      # The raw plan JSON string should be replaced with the placeholder
      raw_value = envelope["payload"]["raw_json"]

      if is_binary(raw_value) do
        refute raw_value =~ "\"objective\""

        assert raw_value =~ "omitted" or raw_value =~ "REDACTED" or
                 raw_value =~ "[structured plan JSON"
      end

      # Envelope should still be JSON-encodable
      assert {:ok, _} = Jason.encode(envelope)
    end

    test "handles map-with-objective-and-tasks plan payload safely" do
      plan_data = %{
        "objective" => "Build the thing",
        "tasks" => [%{"id" => 1, "title" => "Step one"}],
        "plan_id" => "p_42"
      }

      event = make_event(:plan_approved, plan_data, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      # Plan maps are summarized, not passed through raw
      payload = envelope["payload"]
      # Should have summary keys like plan_id, task_count etc., not raw tasks
      assert is_map(payload)
      assert {:ok, _} = Jason.encode(envelope)
    end

    test "non-sensitive data passes through intact" do
      event = make_event(:assistant_message, %{text: "The answer is 42"}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.filter(event, [])

      assert envelope["payload"]["text"] == "The answer is 42"
    end
  end

  # -- Combined session + visibility tests --------------------------------------

  describe "combined filtering" do
    test "user event with matching session passes" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, session_id: "s1")
      assert {:ok, envelope} = ExternalEventFilter.filter(event, session_id: "s1")
      assert envelope["type"] == "user_message"
    end

    test "internal event is denied even with matching session" do
      event = make_event(:internal_op, %{}, visibility: :internal, session_id: "s1")
      assert {:error, :visibility_denied} = ExternalEventFilter.filter(event, session_id: "s1")
    end

    test "nil-visibility allowlisted event with matching session passes" do
      event = make_event(:turn_completed, %{}, session_id: "s1")
      assert {:ok, envelope} = ExternalEventFilter.filter(event, session_id: "s1")
      assert envelope["type"] == "turn_completed"
    end

    test "nil-visibility unlisted event with matching session is still denied" do
      event = make_event(:some_misc_type, %{}, session_id: "s1")

      assert {:error, :nil_visibility_type_not_allowed} =
               ExternalEventFilter.filter(event, session_id: "s1")
    end
  end

  # -- Public API helpers --------------------------------------------------------

  describe "nil_visibility_safe_types/0" do
    test "returns a MapSet of known safe types" do
      types = ExternalEventFilter.nil_visibility_safe_types()
      assert MapSet.member?(types, :user_message)
      assert MapSet.member?(types, :assistant_delta)
      assert MapSet.member?(types, :turn_completed)
      assert MapSet.member?(types, :session_status_changed)
    end
  end

  describe "nil_visibility_type_allowed?/1" do
    test "returns true for allowlisted types" do
      assert ExternalEventFilter.nil_visibility_type_allowed?(:user_message)
      assert ExternalEventFilter.nil_visibility_type_allowed?(:plan_created)
    end

    test "returns false for non-allowlisted types" do
      refute ExternalEventFilter.nil_visibility_type_allowed?(:reloaded)
      refute ExternalEventFilter.nil_visibility_type_allowed?(:internal_op)
    end
  end
end
