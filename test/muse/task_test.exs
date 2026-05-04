defmodule Muse.TaskTest do
  use ExUnit.Case, async: true

  alias Muse.Task

  describe "new/1" do
    test "creates a task with required title" do
      task = Task.new(title: "Add command definition", description: "Update commands.ex")

      assert %Task{} = task
      assert task.title == "Add command definition"
      assert task.description == "Update commands.ex"
      assert task.status == :pending
      assert task.requires_write? == false
      assert task.requires_shell? == false
    end

    test "raises on missing title" do
      assert_raise KeyError, fn ->
        Task.new(description: "No title")
      end
    end

    test "generates stable-ish id when absent" do
      task = Task.new(title: "Test")

      assert is_binary(task.id)
      assert String.starts_with?(task.id, "task_")
    end

    test "accepts deterministic id for testing" do
      task = Task.new(id: "task_1", title: "Test")
      assert task.id == "task_1"
    end

    test "accepts atom keys" do
      task =
        Task.new(
          title: "Inspect files",
          description: "Read modules",
          recommended_muse: :coding,
          target_files: ["lib/muse/commands.ex"],
          requires_write: true,
          requires_shell: false
        )

      assert task.title == "Inspect files"
      assert task.recommended_muse == :coding
      assert task.target_files == ["lib/muse/commands.ex"]
      assert task.requires_write? == true
      assert task.requires_shell? == false
    end

    test "accepts string keys" do
      task =
        Task.new(%{
          "title" => "Inspect files",
          "description" => "Read modules",
          "target_files" => ["lib/muse/commands.ex"],
          "requires_write" => true,
          "requires_shell" => false
        })

      assert task.title == "Inspect files"
      assert task.target_files == ["lib/muse/commands.ex"]
      assert task.requires_write? == true
      assert task.requires_shell? == false
    end

    test "accepts requires_write? with trailing question mark" do
      task = Task.new(title: "Write code", requires_write?: true)
      assert task.requires_write? == true
    end

    test "requires_write? takes precedence over requires_write" do
      task = Task.new(title: "Write code", requires_write?: true, requires_write: false)
      # The explicit ? form wins
      assert task.requires_write? == true
    end

    test "defaults list fields to empty lists" do
      task = Task.new(title: "Test")

      assert task.files == []
      assert task.target_files == []
      assert task.tools == []
      assert task.dependencies == []
      assert task.validation == []
    end

    test "preserves target_files and files lists" do
      task =
        Task.new(
          title: "Implement",
          files: ["lib/a.ex", "lib/b.ex"],
          target_files: ["lib/a.ex", "test/a_test.exs"]
        )

      assert task.files == ["lib/a.ex", "lib/b.ex"]
      assert task.target_files == ["lib/a.ex", "test/a_test.exs"]
    end

    test "defaults booleans to false" do
      task = Task.new(title: "Test")
      assert task.requires_write? == false
      assert task.requires_shell? == false
    end

    test "falls back to :pending for invalid status" do
      task = Task.new(title: "Test", status: :unknown_status)
      assert task.status == :pending
    end

    test "accepts valid custom status" do
      task = Task.new(title: "Test", status: :in_progress)
      assert task.status == :in_progress
    end

    test "accepts all valid task statuses" do
      for status <- Task.statuses() do
        task = Task.new(title: "Test", status: status)
        assert task.status == status
      end
    end

    test "accepts optional fields" do
      task =
        Task.new(
          title: "Implement",
          description: "Write the code",
          recommended_muse: "coding",
          tools: ["read_file", "patch_propose"],
          verification: "Run tests",
          risk_level: :medium,
          approval_required: true
        )

      assert task.recommended_muse == "coding"
      assert task.tools == ["read_file", "patch_propose"]
      assert task.verification == "Run tests"
      assert task.risk_level == :medium
      assert task.approval_required == true
    end

    test "unknown string keys from JSON are ignored without creating atoms" do
      # Verifying no atom leak: unknown keys from JSON input should not crash
      # and should not create atoms that survive in the atom table.
      # We check this by ensuring an unknown key doesn't trigger String.to_atom.
      before_atoms = :erlang.system_info(:atom_count)

      task =
        Task.new(%{
          "title" => "Safe task",
          "description" => "Desc",
          "unknown_key_12345" => "should be ignored",
          "another_unknown_xyz" => "also ignored"
        })

      after_atoms = :erlang.system_info(:atom_count)

      assert %Task{} = task
      assert task.title == "Safe task"

      # Unknown keys should not increase the atom count
      # (Allow for the small number of atoms Elixir may create during test setup)
      assert after_atoms - before_atoms < 3,
             "Unknown JSON keys should not create atoms: #{after_atoms - before_atoms} new atoms"
    end
  end

  describe "statuses/0" do
    test "returns canonical list of task statuses" do
      statuses = Task.statuses()

      assert :draft in statuses
      assert :pending in statuses
      assert :in_progress in statuses
      assert :completed in statuses
      assert :blocked in statuses
      assert :skipped in statuses
    end

    test "all statuses are atoms" do
      for status <- Task.statuses() do
        assert is_atom(status)
      end
    end
  end

  describe "valid_status?/1" do
    test "returns true for canonical statuses" do
      for status <- Task.statuses() do
        assert Task.valid_status?(status)
      end
    end

    test "returns false for non-canonical values" do
      refute Task.valid_status?(:unknown)
      refute Task.valid_status?(nil)
      refute Task.valid_status?("pending")
    end
  end

  describe "to_map/1" do
    test "converts struct to plain map" do
      task =
        Task.new(
          id: "task_1",
          title: "Test",
          description: "Desc",
          requires_write?: true,
          requires_shell?: false
        )

      map = Task.to_map(task)

      assert is_map(map)
      assert map[:title] == "Test"
      assert map[:description] == "Desc"
    end

    test "exports requires_write? as requires_write (no trailing ?)" do
      task = Task.new(title: "Write", requires_write?: true, requires_shell?: false)
      map = Task.to_map(task)

      assert Map.has_key?(map, :requires_write)
      assert Map.has_key?(map, :requires_shell)
      refute Map.has_key?(map, :requires_write?)
      refute Map.has_key?(map, :requires_shell?)
      assert map.requires_write == true
      assert map.requires_shell == false
    end

    test "drops nil values" do
      task = Task.new(id: "task_1", title: "Test")
      map = Task.to_map(task)

      # id and title are present
      assert map[:id] == "task_1"
      assert map[:title] == "Test"
      # nil fields like description are dropped
      refute Map.has_key?(map, :description)
      refute Map.has_key?(map, :recommended_muse)
    end
  end

  describe "from_map/1" do
    test "creates task from plain map" do
      task =
        Task.from_map(%{
          "title" => "Add command",
          "description" => "Update commands.ex",
          "requires_write" => true
        })

      assert %Task{} = task
      assert task.title == "Add command"
      assert task.requires_write? == true
    end

    test "round-trips through to_map and from_map" do
      original =
        Task.new(
          id: "task_1",
          title: "Test",
          description: "Desc",
          requires_write?: true,
          requires_shell?: false,
          target_files: ["a.ex"]
        )

      map = Task.to_map(original)
      restored = Task.from_map(map)

      assert restored.title == original.title
      assert restored.description == original.description
      assert restored.requires_write? == original.requires_write?
      assert restored.requires_shell? == original.requires_shell?
      assert restored.target_files == original.target_files
    end
  end
end
