defmodule Muse.ApprovalGateTest do
  use ExUnit.Case, async: true

  alias Muse.ApprovalGate
  alias Muse.Tool.Spec

  defmodule NoopTool do
    def execute(_args, _context), do: {:ok, %{ok: true}}
  end

  describe "authorize_tool/2" do
    test "allows safe tools that do not require approval" do
      assert :ok = ApprovalGate.authorize_tool(tool_spec(name: "read_file"), %{})

      assert :ok =
               ApprovalGate.authorize_tool(
                 tool_spec(
                   name: "ask_user_question",
                   kind: :interactive,
                   permission: :interactive
                 ),
                 %{}
               )
    end

    test "blocks requires-approval specs through the gate" do
      spec =
        tool_spec(
          name: "future_write_tool",
          kind: :write,
          permission: :write,
          requires_approval: true
        )

      context = %{token: "sk-test-approval-secret"}

      assert {:blocked, reason} = ApprovalGate.authorize_tool(spec, context)
      assert reason =~ "future_write_tool requires explicit write approval"
      assert reason =~ "plan approval does not authorize tool execution"
      refute reason =~ "sk-test-approval-secret"
    end

    test "approved plan context does not unlock write, shell, network, patch, or delete tools" do
      context = approved_plan_context()

      for permission <- [:write, :shell, :network, :patch, :delete] do
        spec =
          tool_spec(
            name: "future_#{permission}_tool",
            kind: permission,
            permission: permission,
            requires_approval: true
          )

        assert {:blocked, reason} = ApprovalGate.authorize_tool(spec, context)
        assert reason =~ "requires explicit #{permission} approval"
        assert reason =~ "plan approval does not authorize tool execution"
      end
    end

    test "approval-scoped permissions are denied by default even without requires_approval" do
      for permission <- [:write, :shell, :network, :patch, :delete] do
        spec =
          tool_spec(
            name: "unsafe_#{permission}_tool",
            kind: permission,
            permission: permission,
            requires_approval: false
          )

        assert {:blocked, reason} = ApprovalGate.authorize_tool(spec, approved_plan_context())
        assert reason =~ "denied by default"
        assert reason =~ "plan approval does not authorize tool execution"
      end
    end
  end

  defp tool_spec(attrs) do
    defaults = [
      name: "read_file",
      description: "Test tool spec",
      handler: NoopTool,
      input_schema: %{},
      kind: :read,
      permission: :read,
      requires_approval: false
    ]

    defaults
    |> Keyword.merge(attrs)
    |> Spec.new!()
  end

  defp approved_plan_context do
    %{
      plan_status: :approved,
      approval_scope: :plan,
      approvals: [
        %{
          scope: :plan,
          status: :approved,
          session_id: "session_1",
          plan_id: "plan_1"
        }
      ],
      active_plan_id: "plan_1"
    }
  end
end
