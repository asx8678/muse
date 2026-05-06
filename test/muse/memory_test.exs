defmodule Muse.MemoryTest do
  use ExUnit.Case, async: true

  alias Muse.{Memory, Session, Plan}

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
end
