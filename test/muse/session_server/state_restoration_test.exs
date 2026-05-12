defmodule Muse.SessionServer.StateRestorationTest do
  @moduledoc """
  Phase 4: Tests for session crash recovery via StateRestoration.

  Verifies that persisted session state (plans, patches, approvals, memory)
  can be restored after a simulated process crash, and that corrupt or
  missing data degrades gracefully to safe defaults.
  """
  use ExUnit.Case, async: false

  alias Muse.{SessionStore, SessionServer.StateRestoration}

  # ── Helpers ──────────────────────────────────────────────────────────

  defp tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "muse-state-restoration-test-#{suffix}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp base_state(base_dir, session_id) do
    %{
      store_base_dir: base_dir,
      session_id: session_id,
      status: :idle,
      plan: nil,
      plans: %{},
      active_plan_id: nil,
      approvals: [],
      approval_binding: nil,
      active_approval: nil,
      pending_patch: nil,
      pending_remote_approval: nil,
      memory: nil
    }
  end

  # ── restore_plan_from_snapshot/1 ─────────────────────────────────────

  describe "restore_plan_from_snapshot/1" do
    test "restores idle state when no snapshot exists" do
      base_dir = tmp_dir!()
      session_id = "crash-test-no-snapshot"
      state = base_state(base_dir, session_id)

      on_exit(fn -> File.rm_rf!(base_dir) end)

      restored = StateRestoration.restore_plan_from_snapshot(state)

      assert restored.status == :idle
      assert restored.plan == nil
      assert restored.plans == %{}
    end

    test "restores snapshot with plan data after simulated crash" do
      base_dir = tmp_dir!()
      session_id = "crash-test-with-plan"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      # Simulate a session that persisted a snapshot before crashing
      SessionStore.save_session(base_dir, session_id, %{
        "status" => "idle",
        "plan" => nil,
        "plans" => %{}
      })

      state = base_state(base_dir, session_id)
      restored = StateRestoration.restore_plan_from_snapshot(state)

      assert restored.status == :idle
      assert restored.session_id == session_id
    end

    test "restores awaiting_plan_approval status with plan" do
      base_dir = tmp_dir!()
      session_id = "crash-test-plan-approval"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      plan_data = %{
        "id" => "plan-1",
        "objective" => "Test objective",
        "status" => "awaiting_approval",
        "tasks" => [],
        "approvals" => [],
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      SessionStore.save_session(base_dir, session_id, %{
        "status" => "awaiting_plan_approval",
        "plan" => plan_data,
        "plans" => %{"plan-1" => plan_data},
        "active_plan_id" => "plan-1",
        "approvals" => [],
        "approval_binding" => nil
      })

      state = base_state(base_dir, session_id)
      restored = StateRestoration.restore_plan_from_snapshot(state)

      assert restored.status == :awaiting_plan_approval
      assert restored.active_plan_id == "plan-1"
    end

    test "downgrades to idle when snapshot has awaiting_patch_approval but no pending_patch" do
      base_dir = tmp_dir!()
      session_id = "crash-test-stuck-patch"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      # Simulate a snapshot where the pending_patch was lost
      SessionStore.save_session(base_dir, session_id, %{
        "status" => "awaiting_patch_approval",
        "pending_patch" => nil,
        "approvals" => [],
        "approval_binding" => nil
      })

      state = base_state(base_dir, session_id)
      restored = StateRestoration.restore_plan_from_snapshot(state)

      # Should downgrade to :idle to avoid stuck session
      assert restored.status == :idle
    end

    test "downgrades to idle when snapshot has awaiting_remote_execution_approval but no pending_remote_approval" do
      base_dir = tmp_dir!()
      session_id = "crash-test-stuck-remote"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      SessionStore.save_session(base_dir, session_id, %{
        "status" => "awaiting_remote_execution_approval",
        "pending_remote_approval" => nil,
        "approvals" => [],
        "approval_binding" => nil
      })

      state = base_state(base_dir, session_id)
      restored = StateRestoration.restore_plan_from_snapshot(state)

      assert restored.status == :idle
    end

    test "handles corrupt JSON gracefully" do
      base_dir = tmp_dir!()
      session_id = "crash-test-corrupt"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      # Write corrupt JSON to session.json
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "session.json"), "not valid json {{{")

      state = base_state(base_dir, session_id)
      restored = StateRestoration.restore_plan_from_snapshot(state)

      # Should return state unchanged (graceful degradation)
      assert restored.status == :idle
      assert restored.plan == nil
    end
  end

  # ── restore_memory/1 ────────────────────────────────────────────────

  describe "restore_memory/1" do
    test "restores memory from persisted storage after simulated crash" do
      base_dir = tmp_dir!()
      session_id = "crash-test-memory"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      # Simulate a session that persisted memory before crashing
      SessionStore.save_session(base_dir, session_id, %{"status" => "idle"})

      SessionStore.save_memory(base_dir, session_id, %{
        "user_goal" => "Build feature",
        "project_facts" => ["Elixir project"],
        "compacted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source_session_id" => session_id
      })

      state = base_state(base_dir, session_id)
      restored = StateRestoration.restore_memory(state)

      assert restored.memory != nil
      assert is_map(restored.memory)
    end

    test "does not overwrite existing memory" do
      base_dir = tmp_dir!()
      session_id = "crash-test-memory-exists"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      SessionStore.save_session(base_dir, session_id, %{"status" => "idle"})

      SessionStore.save_memory(base_dir, session_id, %{
        "user_goal" => "Old memory"
      })

      state = base_state(base_dir, session_id)
      state = %{state | memory: %{"user_goal" => "In-memory memory"}}

      restored = StateRestoration.restore_memory(state)

      # Should keep the in-memory value, not overwrite from disk
      assert restored.memory["user_goal"] == "In-memory memory"
    end

    test "handles missing memory file gracefully" do
      base_dir = tmp_dir!()
      session_id = "crash-test-no-memory"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      # Session exists but no memory file
      SessionStore.save_session(base_dir, session_id, %{"status" => "idle"})

      state = base_state(base_dir, session_id)
      restored = StateRestoration.restore_memory(state)

      # Memory should remain nil
      assert restored.memory == nil
    end

    test "rejects unsafe memory loaded from disk" do
      base_dir = tmp_dir!()
      session_id = "crash-test-unsafe-memory"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      # Write a memory file directly with a secret under a sensitive key
      dir = SessionStore.session_dir(base_dir, session_id)
      File.mkdir_p!(dir)

      unsafe_memory =
        Jason.encode!(%{
          "user_goal" => "Test",
          "password" => "secret-value-should-be-rejected",
          "schema_version" => 1
        })

      File.write!(Path.join(dir, "memory.json"), unsafe_memory)

      state = base_state(base_dir, session_id)
      restored = StateRestoration.restore_memory(state)

      # Unsafe memory should be rejected — memory stays nil
      assert restored.memory == nil
    end
  end

  # ── Full crash recovery simulation ─────────────────────────────────

  describe "full crash recovery simulation" do
    test "session state fully recovers from persisted data" do
      base_dir = tmp_dir!()
      session_id = "full-crash-recovery"

      on_exit(fn -> File.rm_rf!(base_dir) end)

      # Simulate a session that persisted everything before crashing
      SessionStore.save_session(base_dir, session_id, %{
        "status" => "idle",
        "plan" => nil,
        "plans" => %{},
        "approvals" => [],
        "approval_binding" => nil
      })

      SessionStore.append_event(base_dir, session_id, %{
        "type" => "user_message",
        "text" => "do something"
      })

      SessionStore.save_memory(base_dir, session_id, %{
        "user_goal" => "Recover from crash",
        "project_facts" => ["Elixir project"],
        "compacted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source_session_id" => session_id
      })

      # Simulate restart: build fresh state and restore
      state = base_state(base_dir, session_id)
      state = StateRestoration.restore_plan_from_snapshot(state)
      state = StateRestoration.restore_memory(state)

      assert state.status == :idle
      assert state.memory != nil
      assert is_map(state.memory)

      # Verify events are still recoverable from disk
      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, session_id)
      assert length(events) == 1
      assert hd(events)["type"] == "user_message"
    end
  end
end
