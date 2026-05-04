defmodule Muse.ApprovalTest do
  use ExUnit.Case, async: true

  alias Muse.Approval

  describe "content_hash/1" do
    test "returns a stable SHA-256 hash without exposing raw content" do
      left = %{plan_id: "plan-1", version: 1, tasks: [%{title: "A"}, %{title: "B"}]}
      right = %{tasks: [%{title: "A"}, %{title: "B"}], version: 1, plan_id: "plan-1"}

      assert Approval.content_hash(left) == Approval.content_hash(right)
      assert Approval.content_hash(left) =~ ~r/^[a-f0-9]{64}$/
      refute Approval.content_hash(left) =~ "plan-1"
      refute Approval.content_hash(left) =~ "Task"
    end
  end

  describe "content_ref/2" do
    test "summarizes raw content with hash metadata only" do
      raw_plan_json = ~s({"objective":"Use api_key=sk-test-approval-ref-secret"})

      ref = Approval.content_ref(:raw_plan_json, raw_plan_json)

      assert ref.label == "raw_plan_json"
      assert ref.algorithm == "sha256"
      assert ref.hash =~ ~r/^[a-f0-9]{64}$/
      assert ref.bytes > 0
      refute inspect(ref) =~ raw_plan_json
      refute inspect(ref) =~ "sk-test-approval-ref-secret"
    end
  end

  describe "event_payload/1" do
    test "redacts approval reasons and metadata" do
      payload =
        Approval.event_payload(%{
          approval_id: "approval-1",
          reason: "approved with Bearer approval-reason-secret",
          metadata: %{
            headers: ["Authorization: Basic approval-header-secret"],
            note: "api_key=sk-test-approval-metadata-secret"
          }
        })

      rendered = inspect(payload)

      assert payload.approval_id == "approval-1"
      assert rendered =~ "[REDACTED]"
      refute rendered =~ "approval-reason-secret"
      refute rendered =~ "approval-header-secret"
      refute rendered =~ "sk-test-approval-metadata-secret"
    end

    test "replaces raw plan JSON and file contents with content refs" do
      payload =
        Approval.event_payload(%{
          approval_id: "approval-2",
          raw_plan_json: ~s({"objective":"secret sk-test-plan-json-secret"}),
          file_contents: "Authorization: Bearer raw-file-secret",
          metadata: %{safe: "visible"}
        })

      rendered = inspect(payload)

      assert payload.approval_id == "approval-2"
      assert payload.metadata.safe == "visible"
      refute Map.has_key?(payload, :raw_plan_json)
      refute Map.has_key?(payload, :file_contents)
      assert length(payload.content_refs) == 2
      assert Enum.all?(payload.content_refs, &(&1.algorithm == "sha256"))
      assert Enum.all?(payload.content_refs, &(&1.hash =~ ~r/^[a-f0-9]{64}$/))
      refute rendered =~ "sk-test-plan-json-secret"
      refute rendered =~ "raw-file-secret"
    end

    test "removes nested raw content from approval metadata" do
      payload =
        Approval.event_payload(%{
          approval_id: "approval-3",
          metadata: %{
            reviewed: [
              %{path: "lib/example.ex", raw_file_contents: "Bearer nested-raw-secret"}
            ]
          }
        })

      rendered = inspect(payload)

      assert [%{path: "lib/example.ex"}] = payload.metadata.reviewed
      assert [%{label: "raw_file_contents"}] = payload.content_refs
      refute rendered =~ "nested-raw-secret"
    end
  end
end
