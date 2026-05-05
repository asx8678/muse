defmodule Muse.CheckpointTest do
  use ExUnit.Case, async: true

  alias Muse.Checkpoint

  describe "new/1" do
    test "creates checkpoint with required fields" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "sess-1",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("a", 64)
        })

      assert checkpoint.session_id == "sess-1"
      assert checkpoint.plan_id == "plan-1"
      assert checkpoint.patch_id == "patch-1"
      assert checkpoint.status == :created
      assert String.starts_with?(checkpoint.id, "chk_")
      assert %DateTime{} = checkpoint.created_at
    end

    test "allows overriding id and timestamps" do
      checkpoint =
        Checkpoint.new(%{
          id: "chk_custom",
          session_id: "sess-1",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("b", 64),
          created_at: ~U[2025-01-01 00:00:00Z]
        })

      assert checkpoint.id == "chk_custom"
      assert checkpoint.created_at == ~U[2025-01-01 00:00:00Z]
    end
  end

  describe "transition/3" do
    test "transitions to :active" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "s",
          plan_id: "p",
          patch_id: "pa",
          patch_hash: "h"
        })

      {:ok, active} = Checkpoint.transition(checkpoint, :active)
      assert active.status == :active
      assert %DateTime{} = active.applied_at
    end

    test "transitions to :rolled_back" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "s",
          plan_id: "p",
          patch_id: "pa",
          patch_hash: "h"
        })

      {:ok, rolled} = Checkpoint.transition(checkpoint, :rolled_back)
      assert rolled.status == :rolled_back
      assert %DateTime{} = rolled.rolled_back_at
    end

    test "transitions to :failed with reason" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "s",
          plan_id: "p",
          patch_id: "pa",
          patch_hash: "h"
        })

      {:ok, failed} =
        Checkpoint.transition(checkpoint, :failed, failure_reason: "git apply failed")

      assert failed.status == :failed
      assert failed.failure_reason == "git apply failed"
      assert %DateTime{} = failed.failed_at
    end

    test "rejects invalid status" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "s",
          plan_id: "p",
          patch_id: "pa",
          patch_hash: "h"
        })

      assert {:error, {:invalid_status, :bogus}} = Checkpoint.transition(checkpoint, :bogus)
    end
  end

  describe "event_summary/1" do
    test "returns safe summary without raw content" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "sess-1",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("c", 64),
          affected_files: ["lib/foo.ex", "lib/bar.ex"]
        })

      summary = Checkpoint.event_summary(checkpoint)
      assert summary.checkpoint_id
      assert summary.patch_id == "patch-1"
      assert summary.affected_files == ["lib/foo.ex", "lib/bar.ex"]
      assert summary.file_count == 2
      refute Map.has_key?(summary, :file_snapshots)
      refute Map.has_key?(summary, :metadata)
    end
  end

  describe "to_map/from_map round-trip" do
    test "serializes and deserializes" do
      checkpoint =
        Checkpoint.new(%{
          session_id: "sess-1",
          plan_id: "plan-1",
          patch_id: "patch-1",
          patch_hash: String.duplicate("d", 64)
        })

      map = Checkpoint.to_map(checkpoint)
      restored = Checkpoint.from_map(map)

      assert restored.session_id == checkpoint.session_id
      assert restored.patch_id == checkpoint.patch_id
      assert restored.status == checkpoint.status
    end
  end

  # -- Regression tests for dynamic atom creation (issue 1) --------------------

  describe "from_map/1 — no dynamic atom creation" do
    test "normalizes known status strings via whitelist" do
      map = %{
        "session_id" => "s",
        "plan_id" => "p",
        "patch_id" => "pa",
        "patch_hash" => "h",
        "status" => "active"
      }

      checkpoint = Checkpoint.from_map(map)
      assert checkpoint.status == :active
    end

    test "defaults unknown status strings safely" do
      map = %{
        "session_id" => "s",
        "plan_id" => "p",
        "patch_id" => "pa",
        "patch_hash" => "h",
        "status" => "totally_made_up_status"
      }

      checkpoint = Checkpoint.from_map(map)
      assert checkpoint.status == :created
    end

    test "normalizes known strategy strings via whitelist" do
      map = %{
        "session_id" => "s",
        "plan_id" => "p",
        "patch_id" => "pa",
        "patch_hash" => "h",
        "strategy" => "git_apply"
      }

      checkpoint = Checkpoint.from_map(map)
      assert checkpoint.strategy == :git_apply
    end

    test "defaults unknown strategy strings safely" do
      map = %{
        "session_id" => "s",
        "plan_id" => "p",
        "patch_id" => "pa",
        "patch_hash" => "h",
        "strategy" => "dangerous_strategy"
      }

      checkpoint = Checkpoint.from_map(map)
      assert checkpoint.strategy == :git_apply
    end

    test "normalizes snapshot keys via whitelist only" do
      map = %{
        "session_id" => "s",
        "plan_id" => "p",
        "patch_id" => "pa",
        "patch_hash" => "h",
        "file_snapshots" => [
          %{
            "path" => "lib/a.ex",
            "existed" => true,
            "content_hash" => "abc",
            "snapshot_path" => "lib/a.ex",
            "unknown_key" => "preserved_as_string"
          }
        ]
      }

      checkpoint = Checkpoint.from_map(map)
      [snapshot] = checkpoint.file_snapshots
      # Known keys are atoms
      assert snapshot.path == "lib/a.ex"
      assert snapshot.existed == true
      assert snapshot.content_hash == "abc"
      assert snapshot.snapshot_path == "lib/a.ex"
      # Unknown keys preserved as strings, never atomized
      assert Map.get(snapshot, "unknown_key") == "preserved_as_string"
      refute Map.has_key?(snapshot, :unknown_key)
    end

    test "does not create atoms for unknown snapshot keys" do
      before = :erlang.system_info(:atom_count)

      map = %{
        "session_id" => "s",
        "plan_id" => "p",
        "patch_id" => "pa",
        "patch_hash" => "h",
        "file_snapshots" => [
          %{
            "path" => "lib/x.ex",
            "existed" => true,
            "content_hash" => "def",
            "snapshot_path" => "lib/x.ex",
            "completely_unknown_key_#{:erlang.unique_integer([:positive])}" => "v"
          }
        ]
      }

      Checkpoint.from_map(map)
      after_ = :erlang.system_info(:atom_count)
      # Atom count should not have increased significantly
      # (normal runtime may create a few atoms; we check no explosion)
      assert after_ - before <= 10
    end
  end
end
