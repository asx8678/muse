defmodule Muse.Test.FakeToolRunnerTest do
  @moduledoc """
  T0-00 Verification: Muse.Test.FakeToolRunner is deterministic and offline.

  These tests confirm the new `Muse.Test.FakeToolRunner` satisfies
  the acceptance criteria for a "fake tool runner" — it is:
    1. Fully deterministic (same input → same output)
    2. Fully offline (no filesystem, network, or registry calls)
    3. Scriptable via the context map
  """
  use ExUnit.Case, async: true

  alias Muse.Test.FakeToolRunner
  alias Muse.Tool.Result

  # ---------------------------------------------------------------------------
  # Determinism and offline
  # ---------------------------------------------------------------------------

  describe "FakeToolRunner — determinism and offline" do
    test "returns success for known tools without script" do
      context = %{workspace: "/tmp", muse_id: :planning}

      result = FakeToolRunner.run("read_file", %{"path" => "a.ex"}, context)

      assert %Result{} = result
      assert result.success
    end

    test "returns error for unknown tools without script" do
      context = %{workspace: "/tmp", muse_id: :planning}

      result = FakeToolRunner.run("nonexistent_tool", %{}, context)

      assert %Result{} = result
      refute result.success
      assert result.error =~ "unknown tool"
    end

    test "returns blocked for write/shell tools without script" do
      context = %{workspace: "/tmp", muse_id: :planning}

      for tool <- ~w(write_file shell_command network_call delete_file remote_exec) do
        result = FakeToolRunner.run(tool, %{}, context)
        refute result.success
        assert result.error =~ "blocked"
      end
    end

    test "same input produces same output" do
      context = %{workspace: "/tmp", muse_id: :planning}

      result1 = FakeToolRunner.run("read_file", %{"path" => "a.ex"}, context)
      result2 = FakeToolRunner.run("read_file", %{"path" => "a.ex"}, context)

      assert result1.success == result2.success
      assert result1.output == result2.output
    end
  end

  # ---------------------------------------------------------------------------
  # Scripting
  # ---------------------------------------------------------------------------

  describe "FakeToolRunner — scripting" do
    test "uses script for scripted tools" do
      script =
        FakeToolRunner.script(%{
          "read_file" => {:ok, %{content: "hello world", path: "a.ex"}}
        })

      context = %{workspace: "/tmp", muse_id: :planning, fake_tool_script: script}

      result = FakeToolRunner.run("read_file", %{"path" => "a.ex"}, context)

      assert result.success
      assert result.output.content == "hello world"
    end

    test "uses {:error, reason} from script" do
      script =
        FakeToolRunner.script(%{
          "repo_search" => {:error, "workspace not found"}
        })

      context = %{workspace: "/tmp", muse_id: :planning, fake_tool_script: script}

      result = FakeToolRunner.run("repo_search", %{"pattern" => "foo"}, context)

      refute result.success
      assert result.error == "workspace not found"
    end

    test "uses {:blocked, reason} from script" do
      script =
        FakeToolRunner.script(%{
          "shell_command" => {:blocked, "not allowed for planning"}
        })

      context = %{workspace: "/tmp", muse_id: :planning, fake_tool_script: script}

      result = FakeToolRunner.run("shell_command", %{"command" => "ls"}, context)

      refute result.success
      assert result.error =~ "blocked"
      assert result.error =~ "not allowed for planning"
    end

    test "falls through to default for non-scripted tools" do
      script =
        FakeToolRunner.script(%{
          "read_file" => {:ok, %{content: "scripted"}}
        })

      context = %{workspace: "/tmp", muse_id: :planning, fake_tool_script: script}

      # read_file is scripted
      result1 = FakeToolRunner.run("read_file", %{"path" => "a.ex"}, context)
      assert result1.output.content == "scripted"

      # list_files is NOT scripted — falls through to default
      result2 = FakeToolRunner.run("list_files", %{"path" => "."}, context)
      assert result2.success
      assert result2.output.fake == true
    end

    test "plain map value in script wraps as {:ok, output}" do
      script =
        FakeToolRunner.script(%{
          "repo_search" => %{results: [%{file: "a.ex", line: 1}], total: 1, truncated: false}
        })

      context = %{workspace: "/tmp", muse_id: :planning, fake_tool_script: script}

      result = FakeToolRunner.run("repo_search", %{"pattern" => "def"}, context)

      assert result.success
      assert result.output.results == [%{file: "a.ex", line: 1}]
    end
  end

  # ---------------------------------------------------------------------------
  # Contract — matches Tool.Runner.run/3 return type
  # ---------------------------------------------------------------------------

  describe "FakeToolRunner — Result contract" do
    test "always returns %Result{}" do
      context = %{workspace: "/tmp", muse_id: :planning}

      result = FakeToolRunner.run("read_file", %{}, context)
      assert %Result{} = result

      result2 = FakeToolRunner.run("unknown", %{}, context)
      assert %Result{} = result2
    end

    test "invalid tool_name returns error result" do
      context = %{workspace: "/tmp"}

      result = FakeToolRunner.run(123, %{}, context)

      assert %Result{} = result
      refute result.success
    end
  end
end
