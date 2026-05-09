defmodule Muse.Tool.ValidatorTest do
  use ExUnit.Case, async: true

  alias Muse.Tool.{Registry, Validator}

  describe "validate_args/2 — required fields" do
    test "returns ok when all required fields are present" do
      spec = Registry.get("read_file")
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => "lib/muse.ex"})
    end

    test "returns error when required field is missing" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{})
      assert msg =~ "missing required arguments"
      assert msg =~ "path"
    end

    test "returns error when required field is empty string" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => ""})
      assert msg =~ "missing required arguments"
    end

    test "returns error for multiple missing required fields" do
      spec = Registry.get("repo_search")
      assert {:error, msg} = Validator.validate_args(spec, %{})
      assert msg =~ "missing required arguments"
      assert msg =~ "pattern"
    end

    test "returns ok when required fields present even with extra args" do
      spec = Registry.get("read_file")
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => "a.ex", "extra" => "val"})
    end

    test "handles tools with no required fields" do
      spec = Registry.get("list_files")
      assert {:ok, _} = Validator.validate_args(spec, %{})
    end

    test "handles tools with required question field" do
      spec = Registry.get("ask_user_question")
      assert {:ok, _} = Validator.validate_args(spec, %{"question" => "What?"})
      assert {:error, _} = Validator.validate_args(spec, %{})
    end

    test "handles tools with required diff field" do
      spec = Registry.get("patch_propose")
      assert {:ok, _} = Validator.validate_args(spec, %{"diff" => "some diff"})
      assert {:error, _} = Validator.validate_args(spec, %{})
    end

    test "handles tools with required checkpoint_id field" do
      spec = Registry.get("rollback_checkpoint")
      assert {:ok, _} = Validator.validate_args(spec, %{"checkpoint_id" => "chk_123"})
      assert {:error, _} = Validator.validate_args(spec, %{})
    end

    test "handles tools with required command field" do
      spec = Registry.get("test_runner")
      assert {:ok, _} = Validator.validate_args(spec, %{"command" => "mix_test"})
      assert {:error, _} = Validator.validate_args(spec, %{})
    end
  end

  describe "validate_args/2 — type validation" do
    test "rejects integer where string expected for path" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => 123})
      assert msg =~ "path"
      assert msg =~ "expected string"
      assert msg =~ "integer"
    end

    test "rejects list where string expected" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => ["a.ex"]})
      assert msg =~ "expected string"
    end

    test "rejects map where string expected" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => %{"nested" => true}})
      assert msg =~ "expected string"
    end

    test "rejects string where integer expected" do
      spec = Registry.get("read_file")

      assert {:error, msg} =
               Validator.validate_args(spec, %{"path" => "a.ex", "start_line" => "one"})

      assert msg =~ "start_line"
      assert msg =~ "expected integer"
    end

    test "rejects boolean where integer expected" do
      spec = Registry.get("read_file")

      assert {:error, msg} =
               Validator.validate_args(spec, %{"path" => "a.ex", "max_lines" => true})

      assert msg =~ "max_lines"
      assert msg =~ "expected integer"
    end

    test "accepts whole-number float where integer expected" do
      spec = Registry.get("read_file")
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => "a.ex", "start_line" => 1.0})
    end

    test "rejects non-whole float where integer expected" do
      spec = Registry.get("read_file")

      assert {:error, msg} =
               Validator.validate_args(spec, %{"path" => "a.ex", "start_line" => 1.5})

      assert msg =~ "expected integer"
      assert msg =~ "float"
    end

    test "rejects string where boolean expected" do
      spec = Registry.get("list_files")
      assert {:error, msg} = Validator.validate_args(spec, %{"allow_hidden" => "yes"})
      assert msg =~ "allow_hidden"
      assert msg =~ "expected boolean"
    end

    test "accepts boolean where boolean expected" do
      spec = Registry.get("list_files")
      assert {:ok, _} = Validator.validate_args(spec, %{"allow_hidden" => true})
    end

    test "rejects integer where boolean expected" do
      spec = Registry.get("list_files")
      assert {:error, msg} = Validator.validate_args(spec, %{"allow_hidden" => 1})
      assert msg =~ "allow_hidden"
      assert msg =~ "expected boolean"
    end

    test "accepts integer where integer expected" do
      spec = Registry.get("read_file")
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => "a.ex", "max_lines" => 100})
    end

    test "accepts list where array expected" do
      spec = Registry.get("patch_propose")

      assert {:ok, _} =
               Validator.validate_args(spec, %{"diff" => "d", "affected_files" => ["a.ex"]})
    end

    test "rejects string where array expected" do
      spec = Registry.get("patch_propose")

      assert {:error, msg} =
               Validator.validate_args(spec, %{"diff" => "d", "affected_files" => "a.ex"})

      assert msg =~ "affected_files"
      assert msg =~ "expected array"
    end

    test "rejects null where string expected" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => nil})
      # nil should be caught by required field check
      assert msg =~ "missing required"
    end
  end

  describe "validate_args/2 — path constraints" do
    test "rejects path traversal (..) in path arg" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => "../../etc/passwd"})
      assert msg =~ "path"
      assert msg =~ "path traversal"
    end

    test "rejects path traversal with mixed segments" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => "lib/../etc/shadow"})
      assert msg =~ "path traversal"
    end

    test "rejects absolute path in path arg" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => "/etc/passwd"})
      assert msg =~ "absolute"
    end

    test "rejects null bytes in path arg" do
      spec = Registry.get("read_file")
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => "foo.ex\0.txt"})
      assert msg =~ "null bytes"
    end

    test "rejects path exceeding max length" do
      spec = Registry.get("read_file")
      long_path = String.duplicate("a", 5000)
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => long_path})
      assert msg =~ "exceeds maximum length"
    end

    test "accepts normal relative path" do
      spec = Registry.get("read_file")
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => "lib/muse/tool/runner.ex"})
    end

    test "path validation applies to file_path key" do
      spec = Registry.get("test_runner")

      assert {:error, msg} =
               Validator.validate_args(spec, %{
                 "command" => "mix_test_file",
                 "file_path" => "../../etc/shadow"
               })

      assert msg =~ "path traversal"
    end

    test "path validation does not apply to non-path string keys" do
      spec = Registry.get("repo_search")
      # "pattern" is a string but not a path key — traversal chars allowed
      assert {:ok, _} = Validator.validate_args(spec, %{"pattern" => "some..pattern"})
    end

    test "accepts dot-prefixed path without traversal" do
      spec = Registry.get("read_file")
      # Note: hidden path checks are done by Workspace.safe_resolve!, not Validator.
      # The Validator only checks traversal, absolute, null bytes, length.
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => ".config"})
    end

    test "rejects absolute path in file_path arg" do
      spec = Registry.get("test_runner")

      assert {:error, msg} =
               Validator.validate_args(spec, %{
                 "command" => "mix_test_file",
                 "file_path" => "/etc/shadow"
               })

      assert msg =~ "absolute"
    end
  end

  describe "validate_args/2 — numeric constraints" do
    test "rejects negative integer" do
      spec = Registry.get("read_file")

      assert {:error, msg} =
               Validator.validate_args(spec, %{"path" => "a.ex", "start_line" => -1})

      assert msg =~ "start_line"
      assert msg =~ "non-negative"
    end

    test "accepts zero" do
      spec = Registry.get("read_file")
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => "a.ex", "start_line" => 0})
    end

    test "accepts positive integer" do
      spec = Registry.get("read_file")
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => "a.ex", "start_line" => 5})
    end

    test "rejects excessively large integer" do
      spec = Registry.get("read_file")

      assert {:error, msg} =
               Validator.validate_args(spec, %{"path" => "a.ex", "max_lines" => 100_000_000})

      assert msg =~ "exceeds maximum"
    end

    test "handles negative whole-number float" do
      spec = Registry.get("read_file")

      assert {:error, msg} =
               Validator.validate_args(spec, %{"path" => "a.ex", "start_line" => -1.0})

      assert msg =~ "non-negative"
    end
  end

  describe "validate_args/2 — string constraints" do
    test "rejects null bytes in non-path string values" do
      spec = Registry.get("ask_user_question")
      assert {:error, msg} = Validator.validate_args(spec, %{"question" => "hello\0world"})
      assert msg =~ "null bytes"
    end

    test "accepts normal string values" do
      spec = Registry.get("ask_user_question")
      assert {:ok, _} = Validator.validate_args(spec, %{"question" => "What should we do?"})
    end

    test "rejects extremely long strings" do
      spec = Registry.get("ask_user_question")
      long_question = String.duplicate("x", 1_100_000)
      assert {:error, msg} = Validator.validate_args(spec, %{"question" => long_question})
      assert msg =~ "exceeds maximum length"
    end
  end

  describe "validate_args/2 — extra args" do
    test "allows extra args not in schema" do
      spec = Registry.get("read_file")
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => "a.ex", "unknown_key" => 42})
    end
  end

  describe "validate_args/2 — combined validations" do
    test "type error takes precedence over constraint error for wrong type" do
      spec = Registry.get("read_file")
      # path=123 — type error should fire before path constraint checks
      assert {:error, msg} = Validator.validate_args(spec, %{"path" => 123})
      assert msg =~ "expected string"
    end

    test "reports first error encountered" do
      spec = Registry.get("read_file")
      # Multiple invalid args — should report the first one found
      assert {:error, _msg} =
               Validator.validate_args(spec, %{"path" => 123, "max_lines" => "not_a_number"})
    end

    test "validates all registered tools with valid minimal args" do
      for spec <- Registry.all() do
        required =
          Map.get(spec.input_schema, "required") || Map.get(spec.input_schema, :required) || []

        # Build minimal valid args from required fields
        args =
          Enum.reduce(required, %{}, fn key, acc ->
            # Provide type-correct minimal values
            props =
              Map.get(spec.input_schema, "properties") || Map.get(spec.input_schema, :properties) ||
                %{}

            prop = Map.get(props, to_string(key)) || Map.get(props, key) || %{}
            type = Map.get(prop, "type") || Map.get(prop, :type) || "string"

            value =
              case type do
                "string" -> "test_value"
                "integer" -> 1
                "boolean" -> true
                "array" -> []
                "object" -> %{}
                _ -> "test_value"
              end

            Map.put(acc, to_string(key), value)
          end)

        assert {:ok, _} = Validator.validate_args(spec, args),
               "Expected valid args for #{spec.name} with #{inspect(args)}"
      end
    end
  end

  describe "validate_args/2 — edge cases" do
    test "handles atom keys in args" do
      spec = Registry.get("read_file")
      # Internal callers might use atom keys
      assert {:ok, _} = Validator.validate_args(spec, %{path: "a.ex"})
    end

    test "handles nil value for non-required field" do
      spec = Registry.get("list_files")
      assert {:ok, _} = Validator.validate_args(spec, %{"max_entries" => nil})
    end

    test "handles empty args map for tools with no required fields" do
      spec = Registry.get("list_files")
      assert {:ok, _} = Validator.validate_args(spec, %{})
    end

    test "handles git_diff_readonly with optional path" do
      spec = Registry.get("git_diff_readonly")
      assert {:ok, _} = Validator.validate_args(spec, %{})
      assert {:ok, _} = Validator.validate_args(spec, %{"path" => "lib/muse.ex"})
      assert {:error, _} = Validator.validate_args(spec, %{"path" => 123})
      assert {:error, _} = Validator.validate_args(spec, %{"path" => "/etc/shadow"})
    end
  end
end
