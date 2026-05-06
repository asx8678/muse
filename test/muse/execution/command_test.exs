defmodule Muse.Execution.CommandTest do
  use ExUnit.Case, async: true

  alias Muse.Execution.Command

  describe "new/2 — validation" do
    test "creates command with valid executable" do
      assert {:ok, cmd} = Command.new("elixir", args: ["-e", "IO.puts(:hello)"])
      assert cmd.executable == "elixir"
      assert cmd.args == ["-e", "IO.puts(:hello)"]
      assert cmd.runner == :local
      assert cmd.target == :local
    end

    test "rejects empty executable" do
      assert {:error, "executable must be a non-empty string"} = Command.new("")
    end

    test "rejects nil executable" do
      assert {:error, "executable must be a non-empty string"} = Command.new(nil)
    end

    test "rejects executable with NUL character" do
      assert {:error, "executable contains NUL character"} = Command.new("eli\0xir")
    end

    test "rejects executable with newline" do
      assert {:error, "executable contains newline character"} = Command.new("eli\nxir")
    end

    test "rejects executable with path traversal" do
      assert {:error, "executable contains path traversal"} = Command.new("../bin/evil")
    end
  end

  describe "new/2 — args validation" do
    test "accepts list of strings" do
      assert {:ok, cmd} = Command.new("elixir", args: ["-e", "test"])
      assert cmd.args == ["-e", "test"]
    end

    test "accepts empty args list" do
      assert {:ok, cmd} = Command.new("elixir", args: [])
      assert cmd.args == []
    end

    test "rejects non-list args" do
      assert {:error, "args must be a list"} = Command.new("elixir", args: "not a list")
    end

    test "rejects args with control characters" do
      assert {:error, "arguments contain control characters"} =
               Command.new("elixir", args: ["-e", "hello\nworld"])
    end
  end

  describe "new/2 — timeout validation" do
    test "accepts reasonable timeout" do
      assert {:ok, cmd} = Command.new("elixir", timeout_ms: 30_000)
      assert cmd.timeout_ms == 30_000
    end

    test "uses default timeout" do
      assert {:ok, cmd} = Command.new("elixir")
      assert cmd.timeout_ms == 60_000
    end

    test "rejects timeout exceeding max" do
      assert {:error, "timeout_ms exceeds maximum (300000ms)"} =
               Command.new("elixir", timeout_ms: 400_000)
    end

    test "rejects negative timeout" do
      assert {:error, "timeout_ms must be a positive integer"} =
               Command.new("elixir", timeout_ms: -100)
    end
  end

  describe "new/2 — max_output_bytes validation" do
    test "accepts reasonable max output" do
      assert {:ok, cmd} = Command.new("elixir", max_output_bytes: 100_000)
      assert cmd.max_output_bytes == 100_000
    end

    test "rejects max output exceeding limit" do
      assert {:error, "max_output_bytes exceeds maximum (500000)"} =
               Command.new("elixir", max_output_bytes: 600_000)
    end
  end

  describe "new/2 — cwd validation" do
    test "accepts existing directory" do
      cwd = System.tmp_dir!()
      assert {:ok, cmd} = Command.new("elixir", cwd: cwd)
      assert cmd.cwd == Path.expand(cwd)
    end

    test "rejects non-existent directory" do
      assert {:error, "cwd must be an existing directory"} =
               Command.new("elixir", cwd: "/nonexistent/path")
    end

    test "accepts nil cwd" do
      assert {:ok, cmd} = Command.new("elixir", cwd: nil)
      assert cmd.cwd == nil
    end
  end

  describe "safe_display/1" do
    test "returns safe string without secrets" do
      {:ok, cmd} = Command.new("elixir", args: ["-e", "API_KEY=sk-test-secret"])
      display = Command.safe_display(cmd)

      assert display =~ "Command["
      refute display =~ "sk-test-secret"
    end

    test "redacts env values" do
      {:ok, cmd} = Command.new("elixir", env: %{"API_KEY" => "sk-test-secret"})
      display = Command.safe_display(cmd)

      refute display =~ "sk-test-secret"
      assert display =~ "env:"
    end
  end

  describe "local?/1 and remote?/1" do
    test "local? returns true for local target" do
      {:ok, cmd} = Command.new("elixir", target: :local)
      assert Command.local?(cmd)
      refute Command.remote?(cmd)
    end

    test "remote? returns true for remote target" do
      {:ok, cmd} = Command.new("elixir", target: :remote)
      assert Command.remote?(cmd)
      refute Command.local?(cmd)
    end

    test "remote? returns true for ssh target" do
      {:ok, cmd} = Command.new("elixir", target: :ssh)
      assert Command.remote?(cmd)
      refute Command.local?(cmd)
    end
  end

  describe "argv_vector/1" do
    test "returns executable and args as list" do
      {:ok, cmd} = Command.new("mix", args: ["test"])
      assert Command.argv_vector(cmd) == ["mix", "test"]
    end
  end

  describe "new!/2" do
    test "returns command on success" do
      cmd = Command.new!("elixir")
      assert cmd.executable == "elixir"
    end

    test "raises on error" do
      assert_raise ArgumentError, "executable must be a non-empty string", fn ->
        Command.new!("")
      end
    end
  end
end
