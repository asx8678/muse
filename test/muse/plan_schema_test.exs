defmodule Muse.PlanSchemaTest do
  use ExUnit.Case, async: true

  alias Muse.PlanSchema

  describe "schema/0" do
    test "returns expected object shape" do
      schema = PlanSchema.schema()

      assert schema.type == "object"
      assert "objective" in schema.required
      assert "tasks" in schema.required
    end

    test "tasks require title and description" do
      schema = PlanSchema.schema()
      task_schema = schema.properties.tasks

      assert task_schema.type == "array"
      assert task_schema.minItems == 1
      assert "title" in task_schema.items.required
      assert "description" in task_schema.items.required
    end

    test "requires_write and requires_shell have boolean type" do
      schema = PlanSchema.schema()
      task_props = schema.properties.tasks.items.properties

      assert task_props.requires_write.type == "boolean"
      assert task_props.requires_shell.type == "boolean"
      assert task_props.requires_write.default == false
      assert task_props.requires_shell.default == false
    end

    test "risks is an array of strings" do
      schema = PlanSchema.schema()

      assert schema.properties.risks.type == "array"
      assert schema.properties.risks.items.type == "string"
    end
  end

  describe "validate/1" do
    test "accepts valid minimal plan" do
      data = %{
        "objective" => "Add /version command",
        "tasks" => [%{"title" => "Add cmd", "description" => "Update commands.ex"}]
      }

      assert {:ok, normalized} = PlanSchema.validate(data)
      assert normalized["objective"] == "Add /version command"
    end

    test "applies defaults: requires_write, requires_shell, risks" do
      data = %{
        "objective" => "Fix bug",
        "tasks" => [%{"title" => "T1", "description" => "D1"}]
      }

      assert {:ok, normalized} = PlanSchema.validate(data)

      task = hd(normalized["tasks"])
      assert task["requires_write"] == false
      assert task["requires_shell"] == false
      assert normalized["risks"] == []
    end

    test "preserves explicit requires_write and requires_shell" do
      data = %{
        "objective" => "Add feature",
        "tasks" => [
          %{
            "title" => "T1",
            "description" => "D1",
            "requires_write" => true,
            "requires_shell" => true
          }
        ]
      }

      assert {:ok, normalized} = PlanSchema.validate(data)
      task = hd(normalized["tasks"])
      assert task["requires_write"] == true
      assert task["requires_shell"] == true
    end

    test "defaults optional list fields to empty lists" do
      data = %{
        "objective" => "Test",
        "tasks" => [%{"title" => "T1", "description" => "D1"}]
      }

      assert {:ok, normalized} = PlanSchema.validate(data)
      assert normalized["alternatives"] == []
      assert normalized["validation"] == []
      assert normalized["inspected_files"] == []
      assert normalized["likely_changed_files"] == []
      assert normalized["files_expected"] == []
      assert normalized["commands_expected"] == []
    end

    test "rejects missing objective" do
      data = %{"tasks" => [%{"title" => "T1", "description" => "D1"}]}

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "objective is required"))
    end

    test "rejects empty objective" do
      data = %{"objective" => "", "tasks" => [%{"title" => "T1", "description" => "D1"}]}

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "objective must be non-empty"))
    end

    test "rejects non-string objective" do
      data = %{"objective" => 123, "tasks" => [%{"title" => "T1", "description" => "D1"}]}

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "objective must be a string"))
    end

    test "rejects empty tasks" do
      data = %{"objective" => "Do stuff", "tasks" => []}

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "tasks must be non-empty"))
    end

    test "rejects missing tasks" do
      data = %{"objective" => "Do stuff"}

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "tasks is required"))
    end

    test "rejects tasks without title" do
      data = %{"objective" => "Do stuff", "tasks" => [%{"description" => "D1"}]}

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "title is required"))
    end

    test "rejects tasks without description" do
      data = %{"objective" => "Do stuff", "tasks" => [%{"title" => "T1"}]}

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "description is required"))
    end

    test "rejects non-boolean requires_write" do
      data = %{
        "objective" => "Do stuff",
        "tasks" => [%{"title" => "T1", "description" => "D1", "requires_write" => "yes"}]
      }

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "requires_write must be a boolean"))
    end

    test "rejects non-boolean requires_shell" do
      data = %{
        "objective" => "Do stuff",
        "tasks" => [%{"title" => "T1", "description" => "D1", "requires_shell" => 1}]
      }

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "requires_shell must be a boolean"))
    end

    test "rejects non-list risks" do
      data = %{
        "objective" => "Do stuff",
        "tasks" => [%{"title" => "T1", "description" => "D1"}],
        "risks" => "some risk"
      }

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "risks must be a list"))
    end

    test "rejects non-map input" do
      assert {:error, errors} = PlanSchema.validate("not a map")
      assert Enum.any?(errors, &String.contains?(&1, "plan must be a map"))
    end

    test "rejects non-map task items" do
      data = %{"objective" => "Do stuff", "tasks" => ["not a map"]}

      assert {:error, errors} = PlanSchema.validate(data)
      assert Enum.any?(errors, &String.contains?(&1, "must be a map"))
    end

    test "accepts atom keys in data" do
      data = %{
        objective: "Add /version",
        tasks: [%{title: "T1", description: "D1"}]
      }

      assert {:ok, _normalized} = PlanSchema.validate(data)
    end

    test "normalizes tasks with atom keys, always outputs string-key 'tasks'" do
      data = %{
        objective: "Fix bug",
        tasks: [%{title: "T1", description: "D1"}]
      }

      {:ok, normalized} = PlanSchema.validate(data)

      # Output always has string-key "tasks"
      assert Map.has_key?(normalized, "tasks")
      tasks = normalized["tasks"]
      assert is_list(tasks)
      task = hd(tasks)
      assert task["requires_write"] == false
      assert task["requires_shell"] == false
    end

    test "validates the docs/testing.md structured plan example" do
      data = %{
        "objective" => "Add a /version command to Muse.",
        "summary" => "Implement command parsing, dispatch, display, and tests.",
        "tasks" => [
          %{
            "title" => "Add command definition",
            "description" =>
              "Add /version to Muse.Commands slash command list and parser coverage.",
            "target_files" => ["lib/muse/commands.ex", "test/muse/commands_test.exs"],
            "requires_write" => true,
            "requires_shell" => false,
            "verification" => "Parser test confirms /version maps to :version."
          },
          %{
            "title" => "Add dispatch handler",
            "description" => "Add :version handling to Muse.CommandDispatcher.",
            "target_files" => [
              "lib/muse/command_dispatcher.ex",
              "test/muse/command_dispatcher_test.exs"
            ],
            "requires_write" => true,
            "requires_shell" => false,
            "verification" => "Dispatcher test returns version text."
          },
          %{
            "title" => "Verify shared interface behavior",
            "description" => "Ensure CLI/TUI/LiveView command path remains shared.",
            "target_files" => [
              "test/muse/cli/repl_test.exs",
              "test/muse_web/live/home_live_test.exs"
            ],
            "requires_write" => false,
            "requires_shell" => true,
            "verification" => "Run relevant mix tests after patch approval."
          }
        ],
        "risks" => [
          "Version source should work both in Mix/dev and release/escript contexts.",
          "Command behavior should remain consistent across CLI, TUI, and LiveView."
        ]
      }

      assert {:ok, normalized} = PlanSchema.validate(data)
      assert normalized["objective"] == "Add a /version command to Muse."
      assert length(normalized["tasks"]) == 3
      assert length(normalized["risks"]) == 2
    end

    test "accumulates multiple errors" do
      data = %{"tasks" => []}

      assert {:error, errors} = PlanSchema.validate(data)
      assert length(errors) >= 2
    end
  end
end
