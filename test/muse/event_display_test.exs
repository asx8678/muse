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
end
