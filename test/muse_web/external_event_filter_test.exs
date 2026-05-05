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
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows event when session_id option matches event session_id" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, session_id: "s1")
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, session_id: "s1")
    end

    test "denies event when session_id option does not match" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, session_id: "s1")

      assert {:error, :session_mismatch} =
               ExternalEventFilter.to_external_map(event, session_id: "s_other")
    end

    test "denies event when session_id option is set but event session_id is nil" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user)

      assert {:error, :session_mismatch} =
               ExternalEventFilter.to_external_map(event, session_id: "s1")
    end

    test "session mismatch takes priority over visibility check" do
      event = make_event(:internal_op, %{}, visibility: :internal, session_id: "s1")

      assert {:error, :session_mismatch} =
               ExternalEventFilter.to_external_map(event, session_id: "s_wrong")
    end

    test "rejects invalid session_id option with invalid_session_id error" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, session_id: "s1")

      # Path traversal in requested session_id
      assert {:error, {:invalid_session_id, "../x"}} =
               ExternalEventFilter.to_external_map(event, session_id: "../x")

      # Dot-only
      assert {:error, {:invalid_session_id, ".."}} =
               ExternalEventFilter.to_external_map(event, session_id: "..")

      # Empty string
      assert {:error, {:invalid_session_id, ""}} =
               ExternalEventFilter.to_external_map(event, session_id: "")
    end

    test "rejects too-long session_id option with invalid_session_id error" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, session_id: "s1")
      too_long = String.duplicate("a", 257)

      assert {:error, {:invalid_session_id, ^too_long}} =
               ExternalEventFilter.to_external_map(event, session_id: too_long)
    end

    test "invalid session_id error takes priority over visibility and mismatch" do
      event = make_event(:internal_op, %{}, visibility: :internal, session_id: "s1")

      # Invalid session_id should be caught before mismatch or visibility
      assert {:error, {:invalid_session_id, "../bad"}} =
               ExternalEventFilter.to_external_map(event, session_id: "../bad")
    end
  end

  # -- Visibility filter tests --------------------------------------------------

  describe "visibility filtering" do
    test "allows :user visibility events" do
      event = make_event(:user_message, %{text: "hello"}, visibility: :user)
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "denies :internal visibility events" do
      event = make_event(:internal_op, %{}, visibility: :internal)

      assert {:error, {:denied_visibility, :internal}} =
               ExternalEventFilter.to_external_map(event, [])
    end

    test "denies :sensitive visibility events" do
      event = make_event(:secret_op, %{}, visibility: :sensitive)

      assert {:error, {:denied_visibility, :sensitive}} =
               ExternalEventFilter.to_external_map(event, [])
    end

    test "denies :debug visibility events by default" do
      event = make_event(:debug_info, %{}, visibility: :debug)

      assert {:error, {:denied_visibility, :debug}} =
               ExternalEventFilter.to_external_map(event, [])
    end

    test "allows :debug visibility events when allow_debug? is true" do
      event = make_event(:debug_info, %{}, visibility: :debug)
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, allow_debug?: true)
    end

    test "denies :debug visibility events when allow_debug? is false" do
      event = make_event(:debug_info, %{}, visibility: :debug)

      assert {:error, {:denied_visibility, :debug}} =
               ExternalEventFilter.to_external_map(event, allow_debug?: false)
    end

    test "denies unknown visibility values" do
      event = make_event(:unknown_op, %{}, visibility: :unknown)
      assert {:error, :denied_visibility} = ExternalEventFilter.to_external_map(event, [])
    end
  end

  # -- Nil visibility allowlist tests -------------------------------------------

  describe "nil visibility allowlist" do
    test "allows user_message with nil visibility" do
      event = make_event(:user_message, %{text: "hi"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows assistant_delta with nil visibility" do
      event = make_event(:assistant_delta, %{text: "chunk"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows assistant_message with nil visibility" do
      event = make_event(:assistant_message, %{text: "done"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows plan_created with nil visibility" do
      event = make_event(:plan_created, %{objective: "test"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows plan_approved with nil visibility" do
      event = make_event(:plan_approved, %{plan_id: "p1"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows plan_rejected with nil visibility" do
      event = make_event(:plan_rejected, %{plan_id: "p1"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows approval_requested with nil visibility" do
      event = make_event(:approval_requested, %{approval_id: "a1"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows approval_approved with nil visibility" do
      event = make_event(:approval_approved, %{approval_id: "a1"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows approval_rejected with nil visibility" do
      event = make_event(:approval_rejected, %{approval_id: "a1"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows patch_proposed with nil visibility" do
      event =
        make_event(:patch_proposed, %{patch_id: "p1", hash: "abc", affected_files: ["lib/a.ex"]})

      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows patch_approval_requested with nil visibility" do
      event = make_event(:patch_approval_requested, %{patch_id: "p1", hash: "abc"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows patch_approved with nil visibility" do
      event = make_event(:patch_approved, %{patch_id: "p1", status: "approved"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows patch_rejected with nil visibility" do
      event = make_event(:patch_rejected, %{patch_id: "p1", status: "rejected"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows turn_completed with nil visibility" do
      event = make_event(:turn_completed, %{})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows turn_failed with nil visibility" do
      event = make_event(:turn_failed, %{})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows session_status_changed with nil visibility" do
      event = make_event(:session_status_changed, %{status: "active"})
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "denies unlisted type with nil visibility" do
      event = make_event(:some_internal_type, %{})

      assert {:error, :nil_visibility_type_not_allowed} =
               ExternalEventFilter.to_external_map(event, [])
    end

    test "denies :reloaded type with nil visibility (not on allowlist)" do
      event = make_event(:reloaded, %{file: "lib/app.ex"})

      assert {:error, :nil_visibility_type_not_allowed} =
               ExternalEventFilter.to_external_map(event, [])
    end
  end

  # -- Provider/auth/debug denial for nil visibility ----------------------------

  describe "provider/auth/debug denial with nil visibility" do
    test "denies provider/auth debug event when source contains both provider and debug fragments" do
      # assistant_delta is on the allowlist, but source contains both "provider" and "debug"
      event =
        Event.new(:openai_provider_debug, :assistant_delta, %{text: "chunk"},
          id: 1,
          timestamp: ~U[2025-06-15 12:00:00Z],
          visibility: nil
        )

      assert {:error, :provider_auth_debug_denied} =
               ExternalEventFilter.to_external_map(event, [])
    end

    test "denies provider response event when source contains provider and type contains debug fragment" do
      # assistant_message is on the allowlist, source has "provider" and type has "response" fragment
      event =
        Event.new(:provider, :response_approved, %{text: "done"},
          id: 1,
          timestamp: ~U[2025-06-15 12:00:00Z],
          visibility: nil
        )

      # :response_approved is NOT on the safe types list, so it's denied by type check first
      assert {:error, :nil_visibility_type_not_allowed} =
               ExternalEventFilter.to_external_map(event, [])
    end

    test "allows user-message from non-provider source with nil visibility" do
      event =
        Event.new(:cli, :user_message, %{text: "hi"},
          id: 1,
          timestamp: ~U[2025-06-15 12:00:00Z],
          visibility: nil
        )

      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
    end

    test "allows provider source event when type does not contain debug fragment" do
      # source has "provider" but type "assistant_delta" doesn't have debug fragment
      event =
        Event.new(:openai_provider, :assistant_delta, %{text: "chunk"},
          id: 1,
          timestamp: ~U[2025-06-15 12:00:00Z],
          visibility: nil
        )

      # This IS allowed because the type doesn't look debug-ish
      assert {:ok, _} = ExternalEventFilter.to_external_map(event, [])
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

      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

      assert envelope["type"] == "user_message"
      assert envelope["source"] == "test"
      assert envelope["timestamp"] == "2025-06-15T12:00:00Z"
      assert envelope["session_id"] == "s1"
      assert envelope["turn_id"] == "t1"
      assert envelope["seq"] == 3
      assert envelope["visibility"] == "user"
      assert is_map(envelope["payload"])
    end

    test "uses payload key (not data)" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

      assert Map.has_key?(envelope, "payload")
      refute Map.has_key?(envelope, "data")
    end

    test "omits nil optional fields" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

      refute Map.has_key?(envelope, "session_id")
      refute Map.has_key?(envelope, "turn_id")
      refute Map.has_key?(envelope, "seq")
      assert envelope["visibility"] == "user"
    end

    test "omits visibility key when event visibility is nil" do
      event = make_event(:user_message, %{text: "hi"})
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

      refute Map.has_key?(envelope, "visibility")
    end

    test "includes muse_id when present" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, muse_id: "planning")
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])
      assert envelope["muse_id"] == "planning"
    end

    test "all keys are strings (Jason-safe)" do
      event = make_event(:assistant_delta, %{text: "chunk"}, visibility: :user, session_id: "s1")
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

      for key <- Map.keys(envelope) do
        assert is_binary(key), "Expected string key, got: #{inspect(key)}"
      end
    end

    test "envelope is encodable by Jason" do
      event = make_event(:user_message, %{text: "hello world"}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

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
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

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

      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

      refute envelope["payload"]["text"] =~ "super-secret-token-xyz"
    end

    test "omits raw plan JSON through EventDisplay.safe_data" do
      raw_plan_json =
        Jason.encode!(%{
          objective: "Take over the world",
          tasks: [%{id: 1, title: "Build lair"}]
        })

      event = make_event(:plan_created, %{raw_json: raw_plan_json}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

      raw_value = envelope["payload"]["raw_json"]

      if is_binary(raw_value) do
        refute raw_value =~ "\"objective\""
      end

      assert {:ok, _} = Jason.encode(envelope)
    end

    test "non-sensitive data passes through intact" do
      event = make_event(:assistant_message, %{text: "The answer is 42"}, visibility: :user)
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, [])

      assert envelope["payload"]["text"] == "The answer is 42"
    end

    test "omits arbitrary structs rather than inspecting sensitive internals" do
      uri_with_userinfo = %URI{
        scheme: "https",
        userinfo: "user:super-secret-password",
        host: "example.test",
        path: "/resource"
      }

      assert {:ok, map} =
               make_event(:user_message, %{uri: uri_with_userinfo}, visibility: :user)
               |> ExternalEventFilter.to_external_map()

      assert map["payload"]["uri"] == "[struct omitted]"
    end

    test "does not emit raw Muse.Event struct dumps or nested event internals" do
      nested =
        Event.new(:auth, :raw_response_debug, %{token: "nested-event-token-secret"},
          visibility: :sensitive,
          id: 1,
          timestamp: ~U[2025-01-01 00:00:00Z]
        )

      event =
        make_event(:user_message, %{nested_event: nested, safe: "visible"}, visibility: :user)

      assert {:ok, map} = ExternalEventFilter.to_external_map(event, [])

      assert map["payload"]["nested_event"] == "[event omitted]"
      assert map["payload"]["safe"] == "visible"
    end
  end

  # -- Collection filter tests --------------------------------------------------

  describe "filter/2 — collection filtering" do
    test "returns only allowed envelopes from a list of events" do
      events = [
        make_event(:user_message, %{text: "visible"}, id: 1, visibility: :user, session_id: "s1"),
        make_event(:internal_op, %{}, id: 2, visibility: :internal, session_id: "s1"),
        make_event(:secret_op, %{}, id: 3, visibility: :sensitive, session_id: "s1"),
        make_event(:debug_info, %{}, id: 4, visibility: :debug, session_id: "s1")
      ]

      result = ExternalEventFilter.filter(events, session_id: "s1")
      assert length(result) == 1
      assert hd(result)["type"] == "user_message"
    end

    test "filters by session_id" do
      events = [
        make_event(:user_message, %{text: "s1"}, id: 1, visibility: :user, session_id: "s1"),
        make_event(:user_message, %{text: "s2"}, id: 2, visibility: :user, session_id: "s2")
      ]

      result = ExternalEventFilter.filter(events, session_id: "s1")
      assert length(result) == 1
      assert hd(result)["session_id"] == "s1"
    end
  end

  # -- Combined session + visibility tests --------------------------------------

  describe "combined filtering" do
    test "user event with matching session passes" do
      event = make_event(:user_message, %{text: "hi"}, visibility: :user, session_id: "s1")
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, session_id: "s1")
      assert envelope["type"] == "user_message"
    end

    test "internal event is denied even with matching session" do
      event = make_event(:internal_op, %{}, visibility: :internal, session_id: "s1")

      assert {:error, {:denied_visibility, :internal}} =
               ExternalEventFilter.to_external_map(event, session_id: "s1")
    end

    test "nil-visibility allowlisted event with matching session passes" do
      event = make_event(:turn_completed, %{}, session_id: "s1")
      assert {:ok, envelope} = ExternalEventFilter.to_external_map(event, session_id: "s1")
      assert envelope["type"] == "turn_completed"
    end

    test "nil-visibility unlisted event with matching session is still denied" do
      event = make_event(:some_misc_type, %{}, session_id: "s1")

      assert {:error, :nil_visibility_type_not_allowed} =
               ExternalEventFilter.to_external_map(event, session_id: "s1")
    end
  end

  # -- Session id validation tests ----------------------------------------------

  describe "valid_session_id?/1" do
    test "rejects nil" do
      refute ExternalEventFilter.valid_session_id?(nil)
    end

    test "accepts simple non-empty strings" do
      assert ExternalEventFilter.valid_session_id?("session-123_ok")
      assert ExternalEventFilter.valid_session_id?("abc")
    end

    test "rejects empty string" do
      refute ExternalEventFilter.valid_session_id?("")
    end

    test "rejects dot and dotdot" do
      refute ExternalEventFilter.valid_session_id?(".")
      refute ExternalEventFilter.valid_session_id?("..")
    end

    test "rejects path traversal characters" do
      refute ExternalEventFilter.valid_session_id?("../escape")
      refute ExternalEventFilter.valid_session_id?("sub/../escape")
      refute ExternalEventFilter.valid_session_id?("foo/bar")
      refute ExternalEventFilter.valid_session_id?("foo\\bar")
      refute ExternalEventFilter.valid_session_id?("foo\0bar")
    end

    test "rejects non-binary values" do
      refute ExternalEventFilter.valid_session_id?(:atom_session)
      refute ExternalEventFilter.valid_session_id?(123)
    end

    test "accepts session ids up to 256 bytes" do
      # Exactly 256 bytes should be accepted
      sid_256 = String.duplicate("a", 256)
      assert ExternalEventFilter.valid_session_id?(sid_256)
    end

    test "rejects session ids longer than 256 bytes" do
      sid_257 = String.duplicate("a", 257)
      refute ExternalEventFilter.valid_session_id?(sid_257)

      # Very long string
      sid_long = String.duplicate("x", 1000)
      refute ExternalEventFilter.valid_session_id?(sid_long)
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

    test "includes all patch lifecycle types" do
      types = ExternalEventFilter.nil_visibility_safe_types()
      assert MapSet.member?(types, :patch_proposed)
      assert MapSet.member?(types, :patch_approval_requested)
      assert MapSet.member?(types, :patch_approved)
      assert MapSet.member?(types, :patch_rejected)
    end
  end

  describe "nil_visibility_type_allowed?/1" do
    test "returns true for allowlisted types" do
      assert ExternalEventFilter.nil_visibility_type_allowed?(:user_message)
      assert ExternalEventFilter.nil_visibility_type_allowed?(:plan_created)
      assert ExternalEventFilter.nil_visibility_type_allowed?(:patch_proposed)
      assert ExternalEventFilter.nil_visibility_type_allowed?(:patch_approved)
    end

    test "returns false for non-allowlisted types" do
      refute ExternalEventFilter.nil_visibility_type_allowed?(:reloaded)
      refute ExternalEventFilter.nil_visibility_type_allowed?(:internal_op)
    end
  end

  # -- to_external_json/2 -------------------------------------------------------

  describe "to_external_json/2" do
    test "returns JSON-encoded string for allowed events" do
      event = make_event(:user_message, %{text: "hello"}, visibility: :user)
      assert {:ok, json} = ExternalEventFilter.to_external_json(event, [])
      assert is_binary(json)
      assert json =~ "\"user_message\""
      assert json =~ "\"hello\""
    end

    test "returns error for denied events" do
      event = make_event(:internal_op, %{}, visibility: :internal)

      assert {:error, {:denied_visibility, :internal}} =
               ExternalEventFilter.to_external_json(event, [])
    end
  end

  # -- Patch diff capping (PR17) -------------------------------------------------

  describe "patch diff capping for external envelopes" do
    test "patch_proposed event caps large diff to 2000 chars" do
      huge_diff = String.duplicate("a", 5_000)

      event =
        make_event(:patch_proposed, %{patch_id: "p1", diff: huge_diff},
          visibility: :user,
          session_id: "s1"
        )

      {:ok, envelope} = ExternalEventFilter.to_external_map(event, session_id: "s1")
      payload_diff = envelope["payload"]["diff"]
      assert String.length(payload_diff) <= 2_002
      assert String.ends_with?(payload_diff, "…")
    end

    test "patch_proposed event preserves short diff under cap" do
      short_diff = "--- a/foo.ex\n+++ b/foo.ex\n@@ -1 +1 @@\n-old\n+new"

      event =
        make_event(:patch_proposed, %{patch_id: "p1", diff: short_diff},
          visibility: :user,
          session_id: "s1"
        )

      {:ok, envelope} = ExternalEventFilter.to_external_map(event, session_id: "s1")
      assert envelope["payload"]["diff"] == short_diff
    end

    test "non-patch event types are not capped by patch logic" do
      long_text = String.duplicate("x", 5_000)

      event =
        make_event(:assistant_message, %{text: long_text},
          visibility: :user,
          session_id: "s1"
        )

      {:ok, envelope} = ExternalEventFilter.to_external_map(event, session_id: "s1")
      # assistant_message text is capped by string truncation (2000 chars), not patch logic
      assert envelope["payload"]["text"] != nil
    end

    test "caps diff_text key as well as diff key" do
      huge_diff = String.duplicate("x", 3_000)

      event =
        make_event(:patch_proposed, %{patch_id: "p1", diff_text: huge_diff},
          visibility: :user,
          session_id: "s1"
        )

      {:ok, envelope} = ExternalEventFilter.to_external_map(event, session_id: "s1")

      diff_text = envelope["payload"]["diff_text"]
      assert String.ends_with?(diff_text, "…")
    end
  end
end
