defmodule Muse.EventDisplayTest do
  use ExUnit.Case, async: true

  alias Muse.{Event, EventDisplay, Plan, Task}

  describe "summary/1" do
    test "summarizes plan approval with explicit implementation caveat" do
      event = %Event{
        id: 1,
        timestamp: DateTime.utc_now(),
        source: :cli,
        type: :plan_approved,
        data: %{plan_id: "plan_a", version: 4, task_count: 2}
      }

      summary = EventDisplay.summary(event)

      assert summary =~ "Plan approved: plan_a (version 4)"
      assert summary =~ "Status: approved"
      assert summary =~ "2 task(s)"
      assert summary =~ "implementation still requires a later explicit gate"
      refute summary =~ "ready for implementation"
    end

    test "suppresses raw structured plan JSON in text payloads" do
      raw = ~s({"objective":"Secret objective","tasks":[{"title":"Leak","description":"No"}]})

      assert EventDisplay.summary(%{text: raw}) =~ "structured plan JSON omitted"
      refute EventDisplay.summary(%{text: raw}) =~ "Secret objective"
    end
  end

  describe "summary/1 — patch lifecycle" do
    test "summarizes patch_proposed with files, hash, diff, and guidance" do
      event = %Event{
        id: 10,
        timestamp: DateTime.utc_now(),
        source: :patch_muse,
        type: :patch_proposed,
        data: %{
          patch_id: "patch_abc",
          hash: "sha256abc123def",
          files: ["lib/muse/foo.ex", "lib/muse/bar.ex"],
          diff: "diff --git a/lib/muse/foo.ex\n--- a/lib/muse/foo.ex\n+++ b/lib/muse/foo.ex",
          status: :proposed
        }
      }

      summary = EventDisplay.summary(event)

      assert summary =~ "Patch proposed: patch_abc"
      assert summary =~ "Status: proposed"
      assert summary =~ "2 files"
      assert summary =~ "lib/muse/foo.ex"
      assert summary =~ "Hash: sha256abc123"
      assert summary =~ "Diff:"
    end

    test "patch_proposed truncates long file list" do
      files = for i <- 1..6, do: "lib/muse/file#{i}.ex"

      event = %Event{
        id: 11,
        timestamp: DateTime.utc_now(),
        source: :patch_muse,
        type: :patch_proposed,
        data: %{patch_id: "p1", files: files, diff: "short", hash: "abc"}
      }

      summary = EventDisplay.summary(event)
      assert summary =~ "6 files"
      assert summary =~ "and 3 more"
    end

    test "summarizes patch_approval_requested with /approve patch guidance" do
      event = %Event{
        id: 12,
        timestamp: DateTime.utc_now(),
        source: :approval_gate,
        type: :patch_approval_requested,
        data: %{
          patch_id: "patch_xyz",
          hash: "sha256xyz",
          files: ["lib/app.ex"],
          diff: "diff text"
        }
      }

      summary = EventDisplay.summary(event)

      assert summary =~ "Patch approval requested: patch_xyz"
      assert summary =~ "/approve patch or reject with /reject patch"
      assert summary =~ "Hash: sha256xyz"
    end

    test "summarizes patch_approved with no-apply caveat" do
      event = %Event{
        id: 13,
        timestamp: DateTime.utc_now(),
        source: :approval_gate,
        type: :patch_approved,
        data: %{patch_id: "patch_ok", hash: "sha256ok"}
      }

      summary = EventDisplay.summary(event)

      assert summary =~ "Patch approved: patch_ok"
      assert summary =~ "patch apply requires a separate explicit step"
    end

    test "summarizes patch_rejected with no-changes caveat" do
      event = %Event{
        id: 14,
        timestamp: DateTime.utc_now(),
        source: :approval_gate,
        type: :patch_rejected,
        data: %{patch_id: "patch_no", hash: "sha256no"}
      }

      summary = EventDisplay.summary(event)

      assert summary =~ "Patch rejected: patch_no"
      assert summary =~ "No changes applied"
    end
  end

  describe "safe_data/1" do
    test "redacts secrets and replaces nested Plan structs with summaries" do
      plan =
        Plan.new(
          id: "plan_safe",
          objective: "Keep the UI boring",
          tasks: [Task.new(title: "Summarize", description: "Avoid raw JSON")]
        )

      safe = EventDisplay.safe_data(%{api_key: "sk-test-secret", plan: plan})

      assert safe.api_key == "[REDACTED]"
      assert safe.plan.plan_id == "plan_safe"
      assert safe.plan.objective == "Keep the UI boring"
      assert safe.plan.task_count == 1
      refute Map.has_key?(safe.plan, :tasks)
    end

    test "replaces plan-shaped maps with summaries" do
      safe =
        EventDisplay.safe_data(%{
          plan: %{
            "id" => "plan_map",
            "objective" => "Map objective",
            "tasks" => [%{"title" => "One"}, %{"title" => "Two"}]
          }
        })

      assert safe.plan.plan_id == "plan_map"
      assert safe.plan.task_count == 2
      refute Map.has_key?(safe.plan, "tasks")
      refute Map.has_key?(safe.plan, :tasks)
    end
  end

  describe "cap_diff/2" do
    test "returns {:ok, diff} when diff is within limit" do
      assert {:ok, "short diff"} = EventDisplay.cap_diff("short diff", 100)
    end

    test "returns {:truncated, capped} when diff exceeds limit" do
      long = String.duplicate("a", 5_000)
      assert {:truncated, capped} = EventDisplay.cap_diff(long, 4_000)
      assert String.ends_with?(capped, "…")
      assert String.length(capped) == 4_001
    end

    test "handles nil diff" do
      assert {:ok, ""} = EventDisplay.cap_diff(nil, 4_000)
    end

    test "handles non-binary diff" do
      assert {:ok, ""} = EventDisplay.cap_diff(123, 4_000)
    end

    test "uses default max_diff_chars when not specified" do
      long = String.duplicate("x", 5_000)
      assert {:truncated, _} = EventDisplay.cap_diff(long)
    end

    test "patch_proposed summary shows truncated indicator for long diffs" do
      long_diff = String.duplicate("line\n", 2_000)

      event = %Event{
        id: 20,
        timestamp: DateTime.utc_now(),
        source: :patch_muse,
        type: :patch_proposed,
        data: %{patch_id: "p_long", diff: long_diff, hash: "abc", files: ["lib/a.ex"]}
      }

      summary = EventDisplay.summary(event)
      assert summary =~ "truncated"
    end
  end

  describe "safe_data/1 — patch payloads" do
    test "redacts secrets in patch event data" do
      safe =
        EventDisplay.safe_data(%{
          patch_id: "p1",
          diff: "key=sk-test-12345",
          files: ["lib/app.ex"]
        })

      refute safe.diff =~ "sk-test-12345"
      assert safe.diff =~ "[REDACTED]"
    end
  end
end
