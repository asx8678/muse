defmodule Muse.Execution.FakeRemoteRunnerTest do
  use ExUnit.Case, async: true

  alias Muse.Execution.{Command, FakeRemoteRunner}

  describe "capabilities/0" do
    test "declares remote but not ssh or network" do
      caps = FakeRemoteRunner.capabilities()

      assert caps.remote == true
      assert caps.ssh == false
      assert caps.network == false
      assert caps.shell == false
      assert caps.local == false
      assert caps.fake == true
      assert :fake in caps.protocols
    end
  end

  describe "Runner behaviour compliance" do
    test "implements Runner behaviour" do
      behaviours =
        FakeRemoteRunner.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Muse.Execution.Runner in behaviours
    end
  end

  describe "RemoteRunner behaviour compliance" do
    test "implements RemoteRunner behaviour" do
      behaviours =
        FakeRemoteRunner.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Muse.Execution.RemoteRunner in behaviours
    end
  end

  describe "connect/2" do
    test "returns ok with opaque connection ref tuple" do
      assert {:ok, {FakeRemoteRunner, ref, target_id}} = FakeRemoteRunner.connect(%{})
      assert is_reference(ref)
      assert is_binary(target_id)
    end

    test "accepts target_id option" do
      assert {:ok, {FakeRemoteRunner, _ref, target_id}} =
               FakeRemoteRunner.connect(%{}, target_id: "tgt_test")

      assert target_id == "tgt_test"
    end

    test "no persistent_term entries are created" do
      {:ok, _ref} = FakeRemoteRunner.connect(%{}, target_id: "tgt_pt")
      # Verify no persistent_term entries exist for FakeRemoteRunner
      all_terms = :persistent_term.get()

      fake_entries =
        Enum.filter(all_terms, fn
          {{Muse.Execution.FakeRemoteRunner, _}, _} -> true
          _ -> false
        end)

      assert fake_entries == []
    end
  end

  describe "disconnect/1" do
    test "returns ok for valid connection ref" do
      {:ok, ref} = FakeRemoteRunner.connect(%{})
      assert :ok = FakeRemoteRunner.disconnect(ref)
    end

    test "returns ok even for unknown ref (best-effort)" do
      fake_ref = make_ref()
      assert :ok = FakeRemoteRunner.disconnect(fake_ref)
    end
  end

  describe "remote_run/3" do
    test "returns denied for invalid connection ref (bare ref)" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")
      fake_ref = make_ref()

      result = FakeRemoteRunner.remote_run(fake_ref, cmd, [])
      assert result.status == :denied
    end

    test "returns denied for invalid connection ref (wrong module)" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")

      result = FakeRemoteRunner.remote_run({WrongModule, make_ref(), "tgt"}, cmd, [])
      assert result.status == :denied
    end

    test "executes via valid connection ref" do
      {:ok, ref} = FakeRemoteRunner.connect(%{}, target_id: "tgt_fake")
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")

      result = FakeRemoteRunner.remote_run(ref, cmd, [])
      assert result.status == :ok
    end
  end

  describe "run/2 — default outcome (:ok)" do
    test "returns ok result by default" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")
      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert result.status == :ok
      assert result.runner == :fake_remote
    end

    test "returns default fake output" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")
      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert result.output =~ "fake remote output"
    end
  end

  describe "run/2 — configurable outcomes" do
    test "returns :ok outcome via metadata" do
      {:ok, cmd} =
        Command.new("ls",
          target: "tgt_fake",
          metadata: %{fake_outcome: :ok, fake_output: "all good"}
        )

      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert result.status == :ok
      assert result.output =~ "all good"
    end

    test "returns :error outcome via metadata" do
      {:ok, cmd} =
        Command.new("ls",
          target: "tgt_fake",
          metadata: %{fake_outcome: :error, fake_output: "oops"}
        )

      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert result.status == :error
      assert result.exit_status == 1
    end

    test "returns :timed_out outcome via metadata" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake", metadata: %{fake_outcome: :timed_out})
      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert result.status == :timed_out
      assert result.timed_out == true
    end

    test "returns :denied outcome via metadata" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake", metadata: %{fake_outcome: :denied})
      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert result.status == :denied
    end

    test "returns :ok outcome via opts" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")
      assert {:ok, result} = FakeRemoteRunner.run(cmd, fake_outcome: :ok)
      assert result.status == :ok
    end

    test "returns :error outcome via opts" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")
      assert {:ok, result} = FakeRemoteRunner.run(cmd, fake_outcome: :error)
      assert result.status == :error
    end

    test "metadata outcome takes precedence over opts" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake", metadata: %{fake_outcome: :denied})
      assert {:ok, result} = FakeRemoteRunner.run(cmd, fake_outcome: :ok)
      assert result.status == :denied
    end

    test "custom output via opts" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")
      assert {:ok, result} = FakeRemoteRunner.run(cmd, fake_output: "custom output")
      assert result.output =~ "custom output"
    end
  end

  describe "run/2 — output redaction" do
    test "redacts secrets in fake output" do
      {:ok, cmd} =
        Command.new("ls",
          target: "tgt_fake",
          metadata: %{fake_output: "DATABASE_URL=postgres://user:pass@host/db result"}
        )

      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      refute result.output =~ "postgres://user:pass@host/db"
      assert result.output =~ "[REDACTED]"
    end

    test "redacts API keys in fake output" do
      {:ok, cmd} =
        Command.new("ls",
          target: "tgt_fake",
          metadata: %{fake_output: "key is sk-test-secret-key-1234567890abcdef1234567890"}
        )

      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      refute result.output =~ "sk-test-secret-key"
    end

    test "caps output at max_output_bytes" do
      long_output = String.duplicate("x", 100_000)

      {:ok, cmd} =
        Command.new("ls",
          target: "tgt_fake",
          max_output_bytes: 1000,
          metadata: %{fake_output: long_output}
        )

      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert byte_size(result.output) <= 1100
    end
  end

  describe "run/2 — result metadata" do
    test "sets runner to :fake_remote" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")
      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert result.runner == :fake_remote
    end

    test "preserves target in result" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")
      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert result.target == "tgt_fake"
    end

    test "has command_id matching the input" do
      {:ok, cmd} = Command.new("ls", target: "tgt_fake")
      assert {:ok, result} = FakeRemoteRunner.run(cmd, [])
      assert result.command_id == cmd.id
    end
  end
end
