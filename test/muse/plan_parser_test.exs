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

  describe "parse/2 with extract: :fenced" do
    test "behaves identically to fenced: true" do
      text = """
      Some intro text.

      ```json
      {"objective": "Refactor module", "tasks": [{"title": "Split", "description": "Break apart"}]}
      ```
      """

      assert {:ok, %Plan{} = plan1} = PlanParser.parse(text, fenced: true)
      assert {:ok, %Plan{} = plan2} = PlanParser.parse(text, extract: :fenced)
      assert plan1.objective == plan2.objective
    end
  end

  describe "parse/2 with extract: :auto" do
    test "parses strict JSON (same as default)" do
      json = ~s({"objective": "Test", "tasks": [{"title": "T1", "description": "D1"}]})

      assert {:ok, %Plan{}} = PlanParser.parse(json, extract: :auto)
    end

    test "extracts JSON from fenced code block" do
      text = """
      Here is the plan:

      ```json
      {
        "objective": "Add /version",
        "tasks": [{"title": "Add cmd", "description": "Update commands.ex"}]
      }
      ```
      """

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective == "Add /version"
    end

    test "extracts JSON from prose surrounding a single JSON object" do
      text = """
      Sure! Here is the structured plan:

      {
        "objective": "Refactor event stream",
        "tasks": [{"title": "Add GenStage", "description": "Wrap EventStream"}],
        "risks": ["Latency may increase"]
      }

      Let me know if this works for you.
      """

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective == "Refactor event stream"
      assert hd(plan.tasks).title == "Add GenStage"
    end

    test "extracts JSON from prose with intro text and closing text" do
      json_str = ~s({"objective": "Fix bug", "tasks": [{"title": "T1", "description": "D1"}]})
      text = "Here's my plan:\n" <> json_str <> "\nThat should do it."

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective == "Fix bug"
    end

    test "handles fenced blocks even when text does not start with {" do
      text = """
      I'll prepare a plan now.

      ```json
      {"objective": "Test", "tasks": [{"title": "T1", "description": "D1"}]}
      ```
      """

      assert {:ok, %Plan{}} = PlanParser.parse(text, extract: :auto)
    end

    test "returns error for completely invalid text in auto mode" do
      text = "This is just plain text with no JSON at all."

      assert {:error, errors} = PlanParser.parse(text, extract: :auto)
      assert is_list(errors)
      assert length(errors) > 0
    end

    test "picks first JSON object when multiple exist in prose" do
      text = """
      First option:
      {"objective": "Option A", "tasks": [{"title": "A1", "description": "D1"}]}

      Second option:
      {"objective": "Option B", "tasks": [{"title": "B1", "description": "D1"}]}
      """

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective == "Option A"
    end

    test "extract: :auto handles prose with trailing non-JSON content" do
      json_str =
        ~s({"objective": "Add feature X", "tasks": [{"title": "Implement X", "description": "Code it up"}]})

      text = "Here's the plan:\n\n" <> json_str <> "\n\nNote: This plan requires review."

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective == "Add feature X"
    end

    test "extract: :auto prioritizes strict JSON when text starts with {" do
      json = ~s({"objective": "Strict test", "tasks": [{"title": "T1", "description": "D1"}]})

      assert {:ok, %Plan{} = plan} = PlanParser.parse(json, extract: :auto)
      assert plan.objective == "Strict test"
    end

    test "extract: :auto falls back to prose extraction when strict fails" do
      json_str = ~s({"objective": "Auto test", "tasks": [{"title": "T1", "description": "D1"}]})
      text = "Intro:\n" <> json_str

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective == "Auto test"
    end

    test "handles JSON with braces inside string values" do
      json_str =
        ~s({"objective": "Fix {critical} bug in parser", "tasks": [{"title": "Fix brace handling", "description": "The { and } chars must work"}]})

      text = "Here is the plan:\n\n" <> json_str <> "\n\nGood luck!"

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective == "Fix {critical} bug in parser"
    end
  end

  describe "parse/2 with fixture files" do
    @fixtures_dir Path.join([__DIR__, "..", "fixtures", "planning"])

    test "parses valid_plan_v1.json fixture" do
      json = File.read!(Path.join(@fixtures_dir, "valid_plan_v1.json"))

      assert {:ok, %Plan{} = plan} = PlanParser.parse(json)
      assert plan.objective == "Add a /version command to the Muse CLI and web console."
      assert length(plan.tasks) == 3
      assert length(plan.risks) == 2
    end

    test "parses valid_plan_v1.json with extract: :auto" do
      json = File.read!(Path.join(@fixtures_dir, "valid_plan_v1.json"))

      assert {:ok, %Plan{} = plan} = PlanParser.parse(json, extract: :auto)
      assert plan.objective == "Add a /version command to the Muse CLI and web console."
    end

    test "parses minimal_plan_v1.json fixture" do
      json = File.read!(Path.join(@fixtures_dir, "minimal_plan_v1.json"))

      assert {:ok, %Plan{} = plan} = PlanParser.parse(json)
      assert plan.objective == "Fix the login redirect bug."
      assert length(plan.tasks) == 1
      assert hd(plan.tasks).requires_write? == false
      assert hd(plan.tasks).requires_shell? == false
      assert plan.risks == []
    end

    test "parses fenced_plan_v1.md fixture with fenced: true" do
      text = File.read!(Path.join(@fixtures_dir, "fenced_plan_v1.md"))

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, fenced: true)
      assert plan.objective == "Add a /version command to the Muse CLI and web console."
      assert length(plan.tasks) == 3
    end

    test "parses fenced_plan_v1.md fixture with extract: :auto" do
      text = File.read!(Path.join(@fixtures_dir, "fenced_plan_v1.md"))

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective == "Add a /version command to the Muse CLI and web console."
    end

    test "parses prose_plan_v1.md fixture with extract: :auto" do
      text = File.read!(Path.join(@fixtures_dir, "prose_plan_v1.md"))

      assert {:ok, %Plan{} = plan} = PlanParser.parse(text, extract: :auto)
      assert plan.objective == "Refactor the event stream module for back-pressure support."
      assert length(plan.tasks) == 2
    end

    test "rejects prose_plan_v1.md in strict mode" do
      text = File.read!(Path.join(@fixtures_dir, "prose_plan_v1.md"))

      assert {:error, _errors} = PlanParser.parse(text)
    end

    test "rejects invalid_plan_missing_objective.json fixture" do
      json = File.read!(Path.join(@fixtures_dir, "invalid_plan_missing_objective.json"))

      assert {:error, errors} = PlanParser.parse(json)
      assert Enum.any?(errors, &String.contains?(&1, "objective"))
    end

    test "parses unsafe_extra_keys_plan.json fixture — extra keys safely ignored" do
      json = File.read!(Path.join(@fixtures_dir, "unsafe_extra_keys_plan.json"))

      assert {:ok, %Plan{} = plan} = PlanParser.parse(json)
      assert plan.objective == "Add logging middleware."
      assert length(plan.tasks) == 1
      assert plan.metadata == %{}
    end
  end

  describe "parse/2 — error redaction" do
    test "error messages are truncated when too long" do
      huge_invalid_json = "{" <> String.duplicate("x", 500) <> " not valid"

      assert {:error, errors} = PlanParser.parse(huge_invalid_json)
      assert is_list(errors)

      for error <- errors do
        assert String.length(error) <= 250,
               "Error message should be truncated: got #{String.length(error)} chars"
      end
    end

    test "error messages do not echo raw LLM output secrets" do
      json = ~s({"objective": "Do stuff", "tasks": [], "secret_key": "sk-abc123realkey"})

      assert {:error, errors} = PlanParser.parse(json)

      for error <- errors do
        refute String.contains?(error, "sk-abc123realkey")
      end
    end

    test "no exceptions raised on wildly malformed input" do
      dangerous_inputs = [
        "",
        "   ",
        String.duplicate("{", 1000),
        "{[[[[[[",
        "null",
        "true",
        "42",
        ~s("just a string"),
        "<html>not json</html>"
      ]

      for input <- dangerous_inputs do
        result = PlanParser.parse(input)

        assert match?({:error, _}, result) or match?({:ok, %Plan{}}, result),
               "Expected safe return for input: #{String.slice(input, 0, 50)}..."
      end
    end
  end

  describe "parse/2 — no dynamic atoms from arbitrary JSON" do
    test "unknown JSON keys do not create new atoms" do
      json = ~s({
        "objective": "Test",
        "tasks": [{"title": "T1", "description": "D1"}],
        "totally_unknown_key_xyzzy_12345": "should not create atom"
      })

      assert {:ok, %Plan{} = plan} = PlanParser.parse(json)

      struct_map = Map.from_struct(plan)
      refute Map.has_key?(struct_map, :totally_unknown_key_xyzzy_12345)
    end

    test "unknown task-level keys do not create new atoms" do
      json = ~s({
        "objective": "Test",
        "tasks": [{"title": "T1", "description": "D1", "unknown_task_key_abc": "ignored"}]
      })

      assert {:ok, plan} = PlanParser.parse(json)
      task = hd(plan.tasks)
      assert task.title == "T1"
    end

    test "unknown status values default safely without creating atoms" do
      json = ~s({
        "objective": "Test",
        "tasks": [{"title": "T1", "description": "D1"}],
        "status": "totally_fake_status_value"
      })

      assert {:ok, plan} = PlanParser.parse(json)
      assert plan.status == :draft
    end
  end

  describe "parse/2 — extract option precedence" do
    test "extract: takes precedence over fenced: true" do
      text = """
      ```json
      {"objective": "Fenced", "tasks": [{"title": "T1", "description": "D1"}]}
      ```
      """

      # extract: :strict should override fenced: true and reject fenced text
      assert {:error, _errors} = PlanParser.parse(text, fenced: true, extract: :strict)
    end

    test "fenced: true works as backward compat when extract: not given" do
      text = """
      ```json
      {"objective": "Fenced", "tasks": [{"title": "T1", "description": "D1"}]}
      ```
      """

      assert {:ok, %Plan{}} = PlanParser.parse(text, fenced: true)
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

    test "repair prompt does not echo raw LLM output" do
      # Even if someone passes a huge error string, repair_prompt should not
      # echo the raw LLM output — it only uses the error list
      huge_text = String.duplicate("x", 10_000)
      prompt = PlanParser.repair_prompt(huge_text, errors: ["Objective missing"])

      refute prompt =~ String.duplicate("x", 100),
             "Repair prompt should not echo raw LLM output"
    end
  end
end
