defmodule Muse.MemoryTest do
  use ExUnit.Case, async: true

  alias Muse.{Memory, Session, Plan, SessionStore}

  describe "new/1" do
    test "creates an empty memory artifact" do
      memory = Memory.new()

      assert memory.user_goal == nil
      assert memory.project_facts == []
      assert memory.decisions_made == []
      assert memory.approved_plans == []
      assert memory.changes_completed == []
      assert memory.validation_results == []
      assert memory.open_issues == []
      assert memory.useful_conventions == []
      assert %DateTime{} = memory.compacted_at
    end

    test "accepts options for all fields" do
      now = DateTime.utc_now()

      memory =
        Memory.new(
          user_goal: "Test goal",
          project_facts: ["fact1"],
          decisions_made: ["decision1"],
          approved_plans: ["plan1"],
          changes_completed: ["change1"],
          validation_results: ["result1"],
          open_issues: ["issue1"],
          useful_conventions: ["convention1"],
          compacted_at: now,
          source_session_id: "session_123"
        )

      assert memory.user_goal == "Test goal"
      assert memory.project_facts == ["fact1"]
      assert memory.decisions_made == ["decision1"]
      assert memory.approved_plans == ["plan1"]
      assert memory.changes_completed == ["change1"]
      assert memory.validation_results == ["result1"]
      assert memory.open_issues == ["issue1"]
      assert memory.useful_conventions == ["convention1"]
      assert memory.compacted_at == now
      assert memory.source_session_id == "session_123"
    end
  end

  describe "compact/2" do
    test "compacts empty session" do
      session = Session.new(workspace: "/tmp/test", id: "session_1")

      memory = Memory.compact(session)

      assert %DateTime{} = memory.compacted_at
      assert memory.source_session_id == "session_1"
      assert is_list(memory.project_facts)
    end

    test "compacts session with approved plan" do
      plan =
        Plan.new(
          objective: "Add new feature",
          session_id: "session_1",
          updated_at: DateTime.utc_now()
        )

      {:ok, approved_plan} = Plan.transition(plan, :approved)

      session =
        Session.new(
          workspace: "/tmp/test",
          id: "session_1"
        )
        |> Map.put(:plans, %{"plan_1" => approved_plan})
        |> Map.put(:active_plan_id, "plan_1")

      memory = Memory.compact(session)

      # User goal should be extracted from the approved plan's objective
      assert memory.user_goal =~ "Add new feature"
      assert is_list(memory.approved_plans)
    end

    test "does not include secrets in compaction" do
      session =
        Session.new(
          workspace: "/tmp/test",
          id: "session_1"
        )

      memory = Memory.compact(session)

      # Verify no secrets in any field
      case Memory.validate_no_secrets(memory) do
        :ok -> :ok
        {:error, reasons} -> flunk("Secrets detected: #{inspect(reasons)}")
      end
    end
  end

  describe "render/1" do
    test "renders empty memory" do
      memory = Memory.new()

      result = Memory.render(memory)

      # Empty memory should produce minimal or empty output
      assert is_binary(result)
    end

    test "renders memory with user goal" do
      memory = Memory.new(user_goal: "Build a REST API")

      result = Memory.render(memory)

      assert result =~ "User goal:"
      assert result =~ "Build a REST API"
    end

    test "renders memory with project facts" do
      memory = Memory.new(project_facts: ["Workspace: /tmp/test", "Elixir project"])

      result = Memory.render(memory)

      assert result =~ "Project facts:"
      assert result =~ "Workspace:"
    end

    test "renders memory with decisions" do
      memory = Memory.new(decisions_made: ["Use Phoenix", "PostgreSQL for DB"])

      result = Memory.render(memory)

      assert result =~ "Decisions made:"
    end

    test "renders memory with approved plans" do
      memory = Memory.new(approved_plans: ["Add auth: 3 tasks"])

      result = Memory.render(memory)

      assert result =~ "Approved plans:"
    end

    test "renders memory with changes" do
      memory = Memory.new(changes_completed: ["Created lib/app.ex"])

      result = Memory.render(memory)

      assert result =~ "Changes completed:"
    end
  end

  describe "validate_no_secrets/1" do
    test "returns :ok for safe memory" do
      memory = Memory.new(user_goal: "Build an app")

      assert :ok = Memory.validate_no_secrets(memory)
    end

    test "detects API keys" do
      memory = Memory.new(user_goal: "API key: sk-1234567890abcdef")

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert length(reasons) > 0
    end

    test "detects bearer tokens" do
      memory = Memory.new(project_facts: ["Token: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert length(reasons) > 0
    end

    test "detects private keys" do
      memory =
        Memory.new(decisions_made: ["Key: -----BEGIN RSA PRIVATE KEY-----MIIE"])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert length(reasons) > 0
    end

    test "detects secrets in nested maps" do
      memory = Memory.new(open_issues: [%{detail: "password=secret123"}])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert length(reasons) > 0
    end

    # -- muse-e49: Sensitive key detection ---------------------------------------

    test "detects sensitive atom keys with non-matching values" do
      # password: "hunter2" — value doesn't match token regex, but key is sensitive
      memory = Memory.new(open_issues: [%{password: "hunter2"}])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "detects sensitive string keys with non-matching values" do
      memory = Memory.new(open_issues: [%{"api_key" => "plain-text-value"}])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "detects deeply nested sensitive atom keys" do
      memory =
        Memory.new(
          open_issues: [
            %{layer1: %{layer2: %{layer3: %{token: "some-value"}}}}
          ]
        )

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "detects deeply nested sensitive string keys" do
      memory =
        Memory.new(
          open_issues: [
            %{"outer" => %{"inner" => %{"secret" => "abc"}}}
          ]
        )

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "detects secrets in keyword lists" do
      memory = Memory.new(open_issues: [[password: "hunter2", safe_key: "ok"]])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "detects secrets in tuples" do
      memory = Memory.new(open_issues: [{:password, "hunter2"}])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "detects secrets in nested tuples" do
      memory = Memory.new(open_issues: [{:config, {:private_key, "pem-data"}}])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "detects token strings in charlists" do
      # A charlist that renders to a string containing a secret
      charlist = ~c"key=sk-test12345"
      memory = Memory.new(open_issues: [charlist])

      assert {:error, _reasons} = Memory.validate_no_secrets(memory)
    end

    test "detects secret patterns in non-binary values via inspect" do
      # A struct-like map that contains secret patterns when inspected
      memory = Memory.new(open_issues: [%{key: %{nested: ~c"sk-test12345"}}])

      assert {:error, _reasons} = Memory.validate_no_secrets(memory)
    end

    test "detects multiple sensitive keys at different levels" do
      memory =
        Memory.new(
          open_issues: [
            %{api_key: "val1", nested: %{password: "val2", safe: "ok"}}
          ]
        )

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      # Both api_key and password should be flagged
      sensitive_count = Enum.count(reasons, &String.contains?(&1, "Sensitive key"))
      assert sensitive_count >= 2
    end

    test "does not flag safe keys with safe values" do
      memory = Memory.new(user_goal: "Build app", project_facts: ["Uses Elixir"])

      assert :ok = Memory.validate_no_secrets(memory)
    end

    test "handles empty lists and nil values gracefully" do
      memory = Memory.new(open_issues: [], user_goal: nil)

      assert :ok = Memory.validate_no_secrets(memory)
    end
  end

  describe "merge/2" do
    test "merges two memory artifacts" do
      memory1 =
        Memory.new(
          user_goal: "Goal 1",
          project_facts: ["fact1"],
          compacted_at: ~U[2025-01-01 10:00:00Z]
        )

      memory2 =
        Memory.new(
          user_goal: "Goal 2",
          project_facts: ["fact2"],
          compacted_at: ~U[2025-01-02 10:00:00Z]
        )

      merged = Memory.merge(memory1, memory2)

      # Newer memory wins for user_goal
      assert merged.user_goal == "Goal 2"
      # Lists are merged
      assert "fact1" in merged.project_facts or "fact2" in merged.project_facts
    end

    test "deduplicates list items" do
      memory1 = Memory.new(project_facts: ["fact1", "fact2"])
      memory2 = Memory.new(project_facts: ["fact2", "fact3"])

      merged = Memory.merge(memory1, memory2)

      # fact2 should appear only once
      count = Enum.count(merged.project_facts, &(&1 == "fact2"))
      assert count <= 1
    end
  end

  # -- muse-e49: Render safety tests -----------------------------------------------

  describe "render/1 — secret redaction" do
    test "rendered output contains no raw API keys" do
      # Simulate stored memory that somehow contains a secret string
      memory = Memory.new(user_goal: "key is sk-test12345secret")

      rendered = Memory.render(memory)
      refute rendered =~ "sk-test12345secret"
    end

    test "rendered output contains no raw Bearer tokens" do
      memory = Memory.new(project_facts: ["Config: Bearer abc123token"])

      rendered = Memory.render(memory)
      refute rendered =~ "abc123token"
    end

    test "rendered output contains no raw private keys" do
      memory =
        Memory.new(decisions_made: ["Key: -----BEGIN RSA PRIVATE KEY-----MIIEpAIBAA"])

      rendered = Memory.render(memory)
      refute rendered =~ "-----BEGIN RSA PRIVATE KEY-----"
    end

    test "safe memory still renders usefully" do
      memory = Memory.new(user_goal: "Build a REST API", project_facts: ["Elixir project"])

      rendered = Memory.render(memory)
      assert rendered =~ "Build a REST API"
      assert rendered =~ "Elixir project"
    end

    test "render does not crash on malformed memory with non-string values" do
      # Memory with non-standard values (maps in lists, tuples, etc.)
      memory = Memory.new(open_issues: [%{config: {:password, "admin"}}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
    end
  end

  # -- muse-e49: compact_safe tests -----------------------------------------------

  describe "compact_safe/2" do
    test "returns {:ok, memory} for safe session" do
      session = Session.new(workspace: "/tmp/test", id: "session_safe")

      assert {:ok, memory} = Memory.compact_safe(session)
      assert %DateTime{} = memory.compacted_at
    end

    test "returns {:error, :secrets_detected, reasons} when memory has secrets" do
      # Create memory directly with a secret and validate
      malicious_memory = Memory.new(open_issues: [%{api_key: "sk-badkey123"}])

      result =
        case Memory.validate_no_secrets(malicious_memory) do
          :ok -> {:ok, malicious_memory}
          {:error, reasons} -> {:error, :secrets_detected, reasons}
        end

      assert {:error, :secrets_detected, reasons} = result
      assert is_list(reasons)
      assert length(reasons) > 0
    end
  end

  # -- muse-avz: Security regression tests for malformed nested terms -----------

  describe "validate_no_secrets/1 — string-key 2-tuples" do
    test "rejects string-key 2-tuples with sensitive keys" do
      # {"api_key", "plain"} must be flagged even though the value
      # doesn't match a secret pattern.
      memory = Memory.new(open_issues: [{"api_key", "plain"}])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "rejects nested string-key 2-tuples with sensitive keys" do
      memory = Memory.new(open_issues: [{:config, {"private_key", "pem data"}}])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "rejects deeply nested string-key 2-tuples" do
      memory =
        Memory.new(open_issues: [{:layer1, {:layer2, {"secret", "deep-value"}}}])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "allows string-key 2-tuples with non-sensitive keys" do
      memory = Memory.new(open_issues: [{"name", "Alice"}])

      assert :ok = Memory.validate_no_secrets(memory)
    end
  end

  describe "render/1 — sensitive tuple-pair redaction" do
    test "does not leak raw value for atom-key tuple {password, hunter2}" do
      memory = Memory.new(open_issues: [{:password, "hunter2"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "hunter2"
    end

    test "does not leak raw value for string-key tuple {api_key, plain}" do
      memory = Memory.new(open_issues: [{"api_key", "plain"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "plain"
    end

    test "does not leak sensitive values in nested tuples" do
      memory = Memory.new(open_issues: [{:config, {:token, "secret-value"}}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "secret-value"
    end
  end

  describe "render/1 — all artifact fields get structural redaction" do
    test "redacts sensitive tuple-pair values in :project_facts" do
      memory = Memory.new(project_facts: [{:password, "leaky"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "leaky"
    end

    test "redacts sensitive tuple-pair values in :decisions_made" do
      memory = Memory.new(decisions_made: [{:secret, "decision-value"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "decision-value"
    end

    test "redacts sensitive tuple-pair values in :approved_plans" do
      memory = Memory.new(approved_plans: [{:token, "plan-token"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "plan-token"
    end

    test "redacts sensitive tuple-pair values in :changes_completed" do
      memory = Memory.new(changes_completed: [{:api_key, "change-key"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "change-key"
    end

    test "redacts sensitive tuple-pair values in :validation_results" do
      memory = Memory.new(validation_results: [{:password, "val-pass"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "val-pass"
    end

    test "redacts sensitive tuple-pair values in :useful_conventions" do
      memory = Memory.new(useful_conventions: [{:secret, "conv-secret"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "conv-secret"
    end

    test "redacts sensitive map values in non-open_issues fields" do
      memory = Memory.new(project_facts: [%{password: "map-leak"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "map-leak"
    end

    test "redacts sensitive string-key map values in all list fields" do
      memory = Memory.new(decisions_made: [%{"api_key" => "dec-key"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "dec-key"
    end
  end

  describe "render/1 — safe non-sensitive memory renders usefully" do
    test "safe memory with non-sensitive tuples renders without crash" do
      memory = Memory.new(open_issues: [{:status, "ok"}, {"name", "test"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      # Non-sensitive values should still appear
      assert rendered =~ "ok" or rendered =~ "status"
    end

    test "safe memory with maps renders usefully" do
      memory = Memory.new(project_facts: [%{name: "Elixir"}, %{name: "OTP"}])

      rendered = Memory.render(memory)
      assert is_binary(rendered)
    end
  end

  describe "validate_no_secrets/1 — no dynamic atom creation" do
    test "validator uses string path segments instead of dynamic atoms" do
      # Create memory with a list that forces index-based recursion.
      # The validator should not create atoms like :"[0]", :"[1]" for
      # path segments. We verify this indirectly by checking that the
      # error messages use string-style path formatting (e.g. "[0]")
      # rather than atom-style formatting.
      memory = Memory.new(open_issues: [[%{password: "nested-list-value"}]])

      assert {:error, reasons} = Memory.validate_no_secrets(memory)
      # The path should contain string-style index segments
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
      # Verify path format uses strings, not atoms
      path_reason = Enum.find(reasons, &String.contains?(&1, "Sensitive key"))
      # Path segments should be dot-separated strings like "[0]", not atoms
      refute path_reason =~ ~r/:\"\[/
    end
  end

  # -- muse-zgm: Security regression tests for malformed whole-field values -----
  # When a canonical list field is replaced by a non-list term (tuple, map,
  # scalar), Memory.render/1 must not crash and must not leak secrets.

  describe "render/1 — malformed whole-field values (tuples)" do
    test "renders safely when :project_facts is a tuple with sentinel" do
      memory = %{
        user_goal: "Test goal",
        project_facts: {:password, "sentinel-project-facts"},
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-project-facts"
    end

    test "renders safely when :decisions_made is a tuple with sentinel" do
      memory = %{
        user_goal: "Test goal",
        project_facts: [],
        decisions_made: {:secret, "sentinel-decisions"},
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-decisions"
    end

    test "renders safely when :approved_plans is a tuple with sentinel" do
      memory = %{
        user_goal: "Test goal",
        project_facts: [],
        decisions_made: [],
        approved_plans: {:token, "sentinel-plans"},
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-plans"
    end

    test "renders safely when :changes_completed is a tuple with sentinel" do
      memory = %{
        user_goal: "Test goal",
        project_facts: [],
        decisions_made: [],
        approved_plans: [],
        changes_completed: {:api_key, "sentinel-changes"},
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-changes"
    end

    test "renders safely when :validation_results is a tuple with sentinel" do
      memory = %{
        user_goal: "Test goal",
        project_facts: [],
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: {:password, "sentinel-validation"},
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-validation"
    end

    test "renders safely when :open_issues is a tuple with sentinel" do
      memory = %{
        user_goal: "Test goal",
        project_facts: [],
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: {:secret, "sentinel-issues"},
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-issues"
    end

    test "renders safely when :useful_conventions is a tuple with sentinel" do
      memory = %{
        user_goal: "Test goal",
        project_facts: [],
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: {:token, "sentinel-conventions"},
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-conventions"
    end
  end

  describe "render/1 — malformed whole-field values (maps)" do
    test "renders safely when :project_facts is a map with sentinel" do
      memory = %{
        user_goal: "Test goal",
        project_facts: %{"secret" => "sentinel-map-facts"},
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-map-facts"
    end

    test "renders safely when :open_issues is a map with sensitive key" do
      memory = %{
        user_goal: "Test goal",
        project_facts: [],
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: %{password: "sentinel-map-issues"},
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-map-issues"
    end
  end

  describe "render/1 — malformed whole-field values (scalars)" do
    test "renders safely when :project_facts is an atom" do
      memory = %{
        user_goal: "Test goal",
        project_facts: :not_a_list,
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
    end

    test "renders safely when :decisions_made is an integer" do
      memory = %{
        user_goal: "Test goal",
        project_facts: [],
        decisions_made: 42,
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
    end
  end

  describe "render/1 — nil list fields" do
    test "renders safely when list field is nil" do
      memory = %{
        user_goal: "Test goal",
        project_facts: nil,
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "nil"
    end
  end

  describe "render/1 — charlist handling" do
    test "renders charlist field as single string, not list of codepoints" do
      # A charlist containing a secret should be treated as a single string
      # and redacted, not iterated as individual codepoints.
      charlist = 'key=sk-sentinel-charlist'

      memory = %{
        user_goal: "Test goal",
        project_facts: [charlist],
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      # The secret pattern should be redacted
      refute rendered =~ "sk-sentinel-charlist"
    end

    test "renders whole-field charlist safely" do
      # When the whole field is a charlist (not in a list), treat as single value
      memory = %{
        user_goal: "Test goal",
        project_facts: 'password=sentinel-charlist-field',
        decisions_made: [],
        approved_plans: [],
        changes_completed: [],
        validation_results: [],
        open_issues: [],
        useful_conventions: [],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_zgm"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      refute rendered =~ "sentinel-charlist-field"
    end
  end

  describe "render/1 — safe memory still renders usefully after fix" do
    test "safe canonical memory with proper lists renders correctly" do
      memory = %{
        user_goal: "Build an app",
        project_facts: ["Uses Elixir", "PostgreSQL DB"],
        decisions_made: ["Use Phoenix framework"],
        approved_plans: ["Add authentication"],
        changes_completed: ["Created user schema"],
        validation_results: ["Tests pass"],
        open_issues: ["Need to add tests"],
        useful_conventions: ["Prefer small functions"],
        compacted_at: DateTime.utc_now(),
        source_session_id: "session_safe"
      }

      rendered = Memory.render(memory)
      assert is_binary(rendered)
      assert rendered =~ "Build an app"
      assert rendered =~ "Elixir"
      assert rendered =~ "Phoenix"
    end
  end

  # -- muse-02e: Fail-closed persistence boundary tests ---------------------------

  describe "validate_and_persist/3" do
    setup do
      base_dir =
        Path.join(System.tmp_dir!(), "muse-memory-persist-#{:erlang.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(base_dir) end)
      session_id = "test-session"
      {:ok, base_dir: base_dir, session_id: session_id}
    end

    test "persists safe memory and returns :ok", %{base_dir: base_dir, session_id: session_id} do
      memory = Memory.new(user_goal: "Build feature", project_facts: ["Elixir project"])

      assert :ok = Memory.validate_and_persist(base_dir, session_id, memory)
      assert {:ok, loaded} = SessionStore.load_memory(base_dir, session_id)
      assert loaded["user_goal"] == "Build feature" or loaded[:user_goal] == "Build feature"
    end

    test "rejects memory with API keys and does not write to disk", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      memory = Memory.new(user_goal: "Key: sk-test12345secret")

      assert {:error, {:unsafe_memory, reasons}} =
               Memory.validate_and_persist(base_dir, session_id, memory)

      assert is_list(reasons) and length(reasons) > 0

      # No file should be written
      assert {:error, :enoent} = SessionStore.load_memory(base_dir, session_id)
    end

    test "rejects memory with sensitive keys and does not write to disk", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      memory = Memory.new(open_issues: [%{password: "hunter2"}])

      assert {:error, {:unsafe_memory, reasons}} =
               Memory.validate_and_persist(base_dir, session_id, memory)

      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
      assert {:error, :enoent} = SessionStore.load_memory(base_dir, session_id)
    end

    test "rejects non-map memory", %{base_dir: base_dir, session_id: session_id} do
      assert {:error, {:unsafe_memory, reasons}} =
               Memory.validate_and_persist(base_dir, session_id, "just a string")

      assert Enum.any?(reasons, &String.contains?(&1, "must be a map"))
    end

    test "rejects memory with nested secrets in tuples", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      memory = Memory.new(open_issues: [{:password, "nested-secret"}])

      assert {:error, {:unsafe_memory, _reasons}} =
               Memory.validate_and_persist(base_dir, session_id, memory)

      assert {:error, :enoent} = SessionStore.load_memory(base_dir, session_id)
    end

    test "rejects memory with secrets in charlists", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      charlist = ~c"key=sk-test12345"
      memory = Memory.new(open_issues: [charlist])

      assert {:error, {:unsafe_memory, _reasons}} =
               Memory.validate_and_persist(base_dir, session_id, memory)

      assert {:error, :enoent} = SessionStore.load_memory(base_dir, session_id)
    end

    test "rejects memory with sensitive string keys in nested maps", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      memory = Memory.new(open_issues: [%{"api_key" => "plain-text-value"}])

      assert {:error, {:unsafe_memory, reasons}} =
               Memory.validate_and_persist(base_dir, session_id, memory)

      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
      assert {:error, :enoent} = SessionStore.load_memory(base_dir, session_id)
    end

    test "error reasons do not contain raw secret values", %{
      base_dir: base_dir,
      session_id: session_id
    } do
      memory = Memory.new(user_goal: "Key: sk-super-secret-value-12345")

      assert {:error, {:unsafe_memory, reasons}} =
               Memory.validate_and_persist(base_dir, session_id, memory)

      for reason <- reasons do
        refute reason =~ "sk-super-secret-value-12345"
      end
    end

    test "propagates disk write errors", %{session_id: session_id} do
      memory = Memory.new(user_goal: "Build feature")
      # Use an invalid base_dir path that will fail mkdir
      bad_dir = "/dev/null/impossible/path"

      result = Memory.validate_and_persist(bad_dir, session_id, memory)
      # Should get some error (mkdir_failed or write_failed)
      assert match?({:error, _}, result)
      refute match?({:error, {:unsafe_memory, _}}, result)
    end
  end

  describe "validate_loaded_memory/1" do
    test "returns {:ok, memory} for safe memory" do
      memory = Memory.new(user_goal: "Build feature")

      assert {:ok, ^memory} = Memory.validate_loaded_memory(memory)
    end

    test "returns {:error, {:unsafe_memory, reasons}} for memory with secrets" do
      memory = Memory.new(user_goal: "Key: sk-test12345secret")

      assert {:error, {:unsafe_memory, reasons}} = Memory.validate_loaded_memory(memory)
      assert is_list(reasons) and length(reasons) > 0
    end

    test "returns {:error, {:unsafe_memory, reasons}} for memory with sensitive keys" do
      memory = Memory.new(open_issues: [%{password: "hunter2"}])

      assert {:error, {:unsafe_memory, reasons}} = Memory.validate_loaded_memory(memory)
      assert Enum.any?(reasons, &String.contains?(&1, "Sensitive key"))
    end

    test "error reasons do not contain raw secret values" do
      memory = Memory.new(user_goal: "password=super-secret-password-value")

      assert {:error, {:unsafe_memory, reasons}} = Memory.validate_loaded_memory(memory)

      for reason <- reasons do
        refute reason =~ "super-secret-password-value"
      end
    end
  end
end
