defmodule Muse.PlanParserTest do
  use ExUnit.Case, async: true

  alias Muse.PlanParser
  alias Muse.Plan

  describe "parse/2" do
    test "parses valid JSON into a Muse.Plan struct" do
      json = ~s({
        "objective": "Add a /version command to Muse.",
        "summary": "Implement command parsing and dispatch.",
        "tasks": [
          {
            "title": "Add command definition",
            "description": "Add /version to commands.ex",
            "target_files": ["lib/muse/commands.ex"],
            "requires_write": true,
            "requires_shell": false,
            "verification": "Parser test confirms /version maps to :version."
          }
        ],
        "risks": [
          "Version source should work in Mix/dev and release."
        ]
      })

      assert {:ok, %Plan{} = plan} = PlanParser.parse(json)
      assert plan.objective == "Add a /version command to Muse."
      assert plan.summary == "Implement command parsing and dispatch."
      assert length(plan.tasks) == 1
      assert hd(plan.tasks).title == "Add command definition"
      assert hd(plan.tasks).requires_write? == true
      assert hd(plan.tasks).requires_shell? == false
      assert plan.risks == ["Version source should work in Mix/dev and release."]
    end

    test "parses the docs/testing.md structured plan JSON" do
      json = ~s({
        "objective": "Add a /version command to the Muse CLI and web console.",
        "summary": "Implement command parsing, dispatch, display, and tests.",
        "tasks": [
          {
            "title": "Locate command routing",
            "description": "Inspect Muse.Commands and Muse.CommandDispatcher.",
            "target_files": ["lib/muse/commands.ex", "lib/muse/command_dispatcher.ex"],
            "requires_write": false,
            "requires_shell": false,
            "verification": "Confirm command list and dispatch flow."
          }
        ],
        "risks": [
          "CLI, TUI, and LiveView share command behavior; tests should cover all interfaces."
        ]
      })

      assert {:ok, %Plan{} = plan} = PlanParser.parse(json)
      assert plan.objective == "Add a /version command to the Muse CLI and web console."
      assert length(plan.tasks) == 1
      assert hd(plan.tasks).title == "Locate command routing"
      assert hd(plan.tasks).requires_write? == false
    end

    test "rejects malformed JSON" do
      assert {:error, errors} = PlanParser.parse("not json at all {{{")
      assert is_list(errors)
      assert Enum.any?(errors, &String.contains?(&1, "JSON decode error"))
    end

    test "rejects JSON that decodes to non-object" do
      assert {:error, errors} = PlanParser.parse(~s([1, 2, 3]))
      assert is_list(errors)
      assert Enum.any?(errors, &String.contains?(&1, "non-object"))
    end

    test "rejects JSON array" do
      assert {:error, errors} = PlanParser.parse(~s(["just", "strings"]))
      assert is_list(errors)
    end

    test "rejects valid JSON with missing objective" do
      json = ~s({"tasks": [{"title": "T1", "description": "D1"}]})

      assert {:error, errors} = PlanParser.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "objective"))
    end

    test "rejects valid JSON with empty tasks" do
      json = ~s({"objective": "Do stuff", "tasks": []})

      assert {:error, errors} = PlanParser.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "tasks must be non-empty"))
    end

    test "rejects valid JSON with non-boolean requires_write" do
      json = ~s({
        "objective": "Do stuff",
        "tasks": [{"title": "T1", "description": "D1", "requires_write": "yes"}]
      })

      assert {:error, errors} = PlanParser.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "requires_write must be a boolean"))
    end

    test "rejects valid JSON with non-boolean requires_shell" do
      json = ~s({
        "objective": "Do stuff",
        "tasks": [{"title": "T1", "description": "D1", "requires_shell": 1}]
      })

      assert {:error, errors} = PlanParser.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "requires_shell must be a boolean"))
    end

    test "rejects valid JSON with non-list risks" do
      json = ~s({
        "objective": "Do stuff",
        "tasks": [{"title": "T1", "description": "D1"}],
        "risks": "single risk string"
      })

      assert {:error, errors} = PlanParser.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "risks must be a list"))
    end

    test "rejects JSON with task missing title" do
      json = ~s({
        "objective": "Do stuff",
        "tasks": [{"description": "D1"}]
      })

      assert {:error, errors} = PlanParser.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "title is required"))
    end

    test "rejects JSON with task missing description" do
      json = ~s({
        "objective": "Do stuff",
        "tasks": [{"title": "T1"}]
      })

      assert {:error, errors} = PlanParser.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "description is required"))
    end

    test "defaults requires_write and requires_shell when absent in tasks" do
      json = ~s({
        "objective": "Do stuff",
        "tasks": [{"title": "T1", "description": "D1"}]
      })

      assert {:ok, plan} = PlanParser.parse(json)
      assert hd(plan.tasks).requires_write? == false
      assert hd(plan.tasks).requires_shell? == false
    end

    test "handles whitespace-padded JSON" do
      json = ~s(   {"objective": "Test", "tasks": [{"title": "T1", "description": "D1"}]}   )

      assert {:ok, %Plan{}} = PlanParser.parse(json)
    end
  end

  describe "parse/2 with fenced: true" do
    test "extracts JSON from fenced code block" do
      text = """
      Here is my plan:

      ```json
      {
        "objective": "Add /version",
        "tasks": [{"title": "Add cmd", "description": "Update commands.ex"}]
      }
      ```
      """

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, fenced: true)
      assert plan.objective == "Add /version"
    end

    test "extracts JSON from fenced block without json label" do
      text = """
      ```
      {"objective": "Add /version", "tasks": [{"title": "T1", "description": "D1"}]}
      ```
      """

      assert {:ok, %Plan{}} = PlanParser.parse(text, fenced: true)
    end

    test "falls back to raw text when no fence is found" do
      json = ~s({"objective": "Test", "tasks": [{"title": "T1", "description": "D1"}]})

      assert {:ok, %Plan{}} = PlanParser.parse(json, fenced: true)
    end
  end

  describe "repair_prompt/2" do
    test "generates repair prompt with errors" do
      prompt =
        PlanParser.repair_prompt("bad json", errors: ["JSON decode error: unexpected byte"])

      assert prompt =~ "invalid"
      assert prompt =~ "JSON decode error: unexpected byte"
      assert prompt =~ "objective"
      assert prompt =~ "tasks"
      assert prompt =~ "requires_write"
    end

    test "includes retry hint" do
      prompt = PlanParser.repair_prompt("bad", errors: ["Error 1"], max_retries: 2)

      assert prompt =~ "2 retries remaining"
    end

    test "shows last retry warning" do
      prompt = PlanParser.repair_prompt("bad", errors: ["Error 1"], max_retries: 1)

      assert prompt =~ "last retry attempt"
    end

    test "handles missing errors gracefully" do
      prompt = PlanParser.repair_prompt("bad")

      assert prompt =~ "Unknown error"
    end

    test "is usable by conductor for one-shot repair without model calls" do
      # The parser itself does not call models — this test confirms
      # the prompt is a plain string ready for use.
      prompt = PlanParser.repair_prompt("bad", errors: ["Objective missing"])

      assert is_binary(prompt)
      assert prompt =~ "Objective missing"
    end
  end
end
