defmodule Muse.ApprovalAuditTest do
  use ExUnit.Case, async: true

  alias Muse.{Approval, ApprovalAudit, Plan}

  test "approval message prefers server-owned plan approval over metadata fallback" do
    server_approval =
      Approval.new(
        id: "server-approval",
        status: :approved,
        plan_id: "plan-audit",
        plan_version: 1,
        plan_hash: String.duplicate("a", 64)
      )

    plan =
      Plan.new(
        id: "plan-audit",
        status: :approved,
        approvals: [server_approval],
        metadata: %{
          approvals: [
            %{
              id: "fake-metadata-approval",
              status: :approved,
              plan_hash: String.duplicate("0", 64)
            }
          ],
          approval_record: %{id: "fake-approval-record", status: :approved}
        }
      )

    output = ApprovalAudit.approval_message(plan)

    assert output =~ "id=server-approval"
    assert output =~ "hash=#{String.duplicate("a", 64)}"
    refute output =~ "fake-metadata-approval"
    refute output =~ "fake-approval-record"
    refute output =~ String.duplicate("0", 64)
  end

  test "status lines can still use metadata fallback when no plan approval record exists" do
    plan =
      Plan.new(
        id: "legacy-plan",
        status: :approved,
        metadata: %{
          approval_record: %{
            id: "legacy-approval",
            status: :approved,
            plan_hash: String.duplicate("b", 64)
          }
        }
      )

    assert ["- Approval status: approved", record_line] = ApprovalAudit.status_lines(plan)
    assert record_line =~ "id=legacy-approval"
    assert record_line =~ "hash=#{String.duplicate("b", 64)}"
  end
end
