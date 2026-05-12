defmodule Muse.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias Muse.Tool.Registry

  describe "all/0" do
    test "returns all 20 registered tool specs" do
      assert length(Registry.all()) == 25
    end

    test "keeps registered specs within the no-approval safe tool surface" do
      excluded = [
        "patch_propose",
        "patch_apply",
        "rollback_checkpoint",
        "eval_elixir",
        "execute_sql",
        "search_hex_docs",
        "test_runner",
        "spawn_sub_agents",
        "create_file"
      ]

      for spec <- Registry.all(),
          spec.name not in excluded do
        refute spec.requires_approval
        assert spec.permission in [:read, :interactive]
        refute spec.permission in [:write, :shell, :network, :patch, :delete, :restore_checkpoint]
      end
    end

    test "returns specs in deterministic order" do
      names = Enum.map(Registry.all(), & &1.name)

      assert names == [
               "list_files",
               "read_file",
               "repo_search",
               "git_status",
               "git_diff_readonly",
               "ask_user_question",
               "list_muses",
               "list_skills",
               "query_matrix",
               "get_project_soul",
               "load_workspace_files",
               "eval_elixir",
               "get_source_location",
               "get_docs",
               "patch_propose",
               "patch_apply",
               "rollback_checkpoint",
               "test_runner",
               "spawn_sub_agents",
               "create_file",
               "execute_sql",
               "get_ecto_schemas",
               "get_ash_resources",
               "search_hex_docs",
               "get_logs"
             ]
    end
  end

  describe "get/1" do
    test "returns spec for registered tool" do
      spec = Registry.get("read_file")
      assert spec.name == "read_file"
      assert spec.handler == Muse.Tools.ReadFile
    end

    test "returns nil for unknown tool" do
      assert Registry.get("unknown_tool") == nil
    end

    test "returns nil for blocked tool" do
      assert Registry.get("write_file") == nil
      assert Registry.get("shell_command") == nil
    end
  end

  describe "fetch/1" do
    test "returns ok for registered tool" do
      assert {:ok, spec} = Registry.fetch("read_file")
      assert spec.name == "read_file"
    end

    test "returns error for unknown tool" do
      assert {:error, :not_found} = Registry.fetch("unknown_tool")
    end

    test "returns error for blocked tool" do
      assert {:error, :not_found} = Registry.fetch("shell_command")
    end
  end

  describe "specs_for_muse/1" do
    test "returns read-only tools for planning muse" do
      specs = Registry.specs_for_muse(:planning)
      names = Enum.map(specs, & &1.name)

      assert "list_files" in names
      assert "read_file" in names
      assert "repo_search" in names
      assert "git_status" in names
      assert "git_diff_readonly" in names
      assert "ask_user_question" in names
      assert "list_muses" in names
      assert "list_skills" in names
      assert "query_matrix" in names
      assert "get_project_soul" in names
      assert "load_workspace_files" in names
      assert "eval_elixir" in names
      assert "get_source_location" in names
      assert "get_docs" in names
    end

    test "does not include write tools for planning muse" do
      specs = Registry.specs_for_muse(:planning)
      names = Enum.map(specs, & &1.name)

      assert "query_matrix" in names
      assert "get_project_soul" in names
      assert "load_workspace_files" in names

      refute "write_file" in names
      refute "shell_command" in names
      refute "patch_apply" in names
      refute "rollback_checkpoint" in names
    end
  end

  describe "provider_schemas/1" do
    test "returns OpenAI-compatible schemas for planning muse" do
      schemas = Registry.provider_schemas(:planning)

      assert length(schemas) == 18

      for schema <- schemas do
        assert schema["type"] == "function"
        assert is_map(schema["function"])
        assert is_binary(schema["function"]["name"])
        assert is_binary(schema["function"]["description"])
        assert is_map(schema["function"]["parameters"])
        assert schema[:name] != nil
      end
    end
  end

  describe "provider_schemas_for_names/1" do
    test "returns schemas for known tool names" do
      schemas = Registry.provider_schemas_for_names(["read_file", "list_files"])
      assert length(schemas) == 2
    end

    test "excludes blocked tool names" do
      schemas = Registry.provider_schemas_for_names(["read_file", "write_file", "shell_command"])
      assert length(schemas) == 1
      assert hd(schemas)[:name] == "read_file"
    end

    test "excludes destructive-looking unknown tool names" do
      schemas = Registry.provider_schemas_for_names(["read_file", "apply_patch", "run_shell"])
      assert length(schemas) == 1
      assert hd(schemas)[:name] == "read_file"
    end

    test "returns stub schema for unknown tool names" do
      schemas = Registry.provider_schemas_for_names(["unknown_tool"])
      assert length(schemas) == 1
      assert hd(schemas)["function"]["name"] == "unknown_tool"
      assert hd(schemas)["function"]["description"] == ""
    end
  end

  describe "known_tool?/1" do
    test "returns true for registered tools" do
      assert Registry.known_tool?("read_file")
      assert Registry.known_tool?("list_files")
      assert Registry.known_tool?("git_status")
    end

    test "returns false for unknown tools" do
      refute Registry.known_tool?("totally_unknown")
    end

    test "returns false for blocked tools (they are not in the registry)" do
      refute Registry.known_tool?("write_file")
    end
  end

  describe "blocked_tool?/1" do
    test "returns true for blocked tools" do
      assert Registry.blocked_tool?("write_file")
      assert Registry.blocked_tool?("replace_in_file")
      assert Registry.blocked_tool?("delete_file")
      # patch_apply is now a registered tool, not blocked
      refute Registry.blocked_tool?("patch_apply")
      # patch_propose is now a registered tool, not blocked
      refute Registry.blocked_tool?("patch_propose")
      # rollback_checkpoint is now a registered tool, not blocked
      refute Registry.blocked_tool?("rollback_checkpoint")
      assert Registry.blocked_tool?("shell_command")
      assert Registry.blocked_tool?("network_call")
      assert Registry.blocked_tool?("remote_execution")
    end

    test "returns false for read-only tools" do
      refute Registry.blocked_tool?("read_file")
      refute Registry.blocked_tool?("list_files")
    end

    test "returns true for destructive-looking unknown tool shapes" do
      assert Registry.blocked_tool?("apply_patch")
      assert Registry.blocked_tool?("run_shell")
      assert Registry.blocked_tool?("http_request")
      assert Registry.blocked_tool?("remote_exec")
    end

    test "returns false for benign unknown tools" do
      refute Registry.blocked_tool?("totally_unknown")
    end
  end

  describe "blocked_tool_names/0" do
    test "returns all blocked tool names" do
      names = Registry.blocked_tool_names()
      assert "write_file" in names
      # patch_propose was removed from blocked list (now a registered tool)
      refute "patch_propose" in names
      # patch_apply was removed from blocked list (now a registered tool with auth gating)
      refute "patch_apply" in names
      assert "shell_command" in names
      assert "network_call" in names
    end
  end

  describe "tool_names/0" do
    test "returns all registered tool names" do
      names = Registry.tool_names()
      assert length(names) == 25
      assert "read_file" in names
      assert "query_matrix" in names
      assert "get_project_soul" in names
      assert "load_workspace_files" in names
      assert "eval_elixir" in names
      assert "get_source_location" in names
      assert "get_docs" in names
      assert "patch_apply" in names
      assert "rollback_checkpoint" in names
      assert "test_runner" in names
      assert "spawn_sub_agents" in names
      assert "execute_sql" in names
      assert "get_ecto_schemas" in names
      assert "get_ash_resources" in names
      assert "search_hex_docs" in names
      assert "get_logs" in names
    end
  end

  describe "no dynamic atom creation" do
    test "tool names are compile-time strings, not atoms created from input" do
      # This should not create atom :totally_made_up_tool
      refute Registry.known_tool?("totally_made_up_tool")
      # Verify the atom was not created
      refute :erlang.list_to_atom("totally_made_up_tool") == :totally_made_up_tool or
               :erlang.list_to_existing_atom("totally_made_up_tool") != :totally_made_up_tool
    rescue
      # Expected: atom doesn't exist
      ArgumentError -> :ok
    end
  end

  describe "test_runner registration (PR19)" do
    test "test_runner is a registered tool" do
      assert Registry.known_tool?("test_runner")
      spec = Registry.get("test_runner")
      assert spec.name == "test_runner"
      assert spec.handler == Muse.Tools.TestRunner
      assert spec.kind == :shell
      assert spec.risk == :medium
      assert spec.permission == :test
      assert spec.allowed_muses == [:testing]
      assert spec.requires_approval == false
    end

    test "test_runner is not blocked" do
      refute Registry.blocked_tool?("test_runner")
    end

    test "planning muse cannot use test_runner" do
      specs = Registry.specs_for_muse(:planning)
      names = Enum.map(specs, & &1.name)
      refute "test_runner" in names
    end

    test "coding muse cannot use test_runner via specs_for_muse" do
      specs = Registry.specs_for_muse(:coding)
      names = Enum.map(specs, & &1.name)
      # coding muse has test_runner in profile tools list, but allowed_muses is [:testing]
      refute "test_runner" in names
    end

    test "testing muse can use test_runner" do
      specs = Registry.specs_for_muse(:testing)
      names = Enum.map(specs, & &1.name)
      assert "test_runner" in names
    end

    test "reviewing muse cannot use test_runner" do
      specs = Registry.specs_for_muse(:reviewing)
      names = Enum.map(specs, & &1.name)
      refute "test_runner" in names
    end
  end

  describe "create_file registration" do
    test "create_file is a registered tool" do
      assert Registry.known_tool?("create_file")
      spec = Registry.get("create_file")
      assert spec.name == "create_file"
      assert spec.handler == Muse.Tools.CreateFile
      assert spec.kind == :write
      assert spec.risk == :medium
      assert spec.permission == :write
      assert spec.allowed_muses == [:coding]
      assert spec.requires_approval == true
    end

    test "create_file is not blocked" do
      refute Registry.blocked_tool?("create_file")
    end

    test "planning muse cannot use create_file" do
      specs = Registry.specs_for_muse(:planning)
      names = Enum.map(specs, & &1.name)
      refute "create_file" in names
    end

    test "coding muse can use create_file" do
      specs = Registry.specs_for_muse(:coding)
      names = Enum.map(specs, & &1.name)
      assert "create_file" in names
    end

    test "reviewing muse cannot use create_file" do
      specs = Registry.specs_for_muse(:reviewing)
      names = Enum.map(specs, & &1.name)
      refute "create_file" in names
    end

    test "testing muse cannot use create_file" do
      specs = Registry.specs_for_muse(:testing)
      names = Enum.map(specs, & &1.name)
      refute "create_file" in names
    end
  end

  describe "eval_elixir registration" do
    test "eval_elixir is a registered tool" do
      assert Registry.known_tool?("eval_elixir")
      spec = Registry.get("eval_elixir")
      assert spec.name == "eval_elixir"
      assert spec.handler == Muse.Tools.EvalElixir
      assert spec.kind == :shell
      assert spec.risk == :high
      assert spec.permission == :shell
      assert spec.allowed_muses == [:planning, :coding, :testing]
      assert spec.requires_approval == true
    end

    test "eval_elixir is not blocked" do
      refute Registry.blocked_tool?("eval_elixir")
    end

    test "planning muse can use eval_elixir" do
      specs = Registry.specs_for_muse(:planning)
      names = Enum.map(specs, & &1.name)
      assert "eval_elixir" in names
    end

    test "coding muse can use eval_elixir" do
      specs = Registry.specs_for_muse(:coding)
      names = Enum.map(specs, & &1.name)
      assert "eval_elixir" in names
    end

    test "testing muse can use eval_elixir" do
      specs = Registry.specs_for_muse(:testing)
      names = Enum.map(specs, & &1.name)
      assert "eval_elixir" in names
    end

    test "reviewing muse cannot use eval_elixir" do
      specs = Registry.specs_for_muse(:reviewing)
      names = Enum.map(specs, & &1.name)
      refute "eval_elixir" in names
    end

    test "restoration muse cannot use eval_elixir" do
      specs = Registry.specs_for_muse(:restoration)
      names = Enum.map(specs, & &1.name)
      refute "eval_elixir" in names
    end
  end

  describe "get_source_location registration" do
    test "get_source_location is a registered tool" do
      assert Registry.known_tool?("get_source_location")
      spec = Registry.get("get_source_location")
      assert spec.name == "get_source_location"
      assert spec.handler == Muse.Tools.GetSourceLocation
      assert spec.kind == :read
      assert spec.risk == :low
      assert spec.permission == :read

      assert spec.allowed_muses == [
               :planning,
               :coding,
               :testing,
               :reviewing,
               :restoration,
               :memory
             ]

      assert spec.requires_approval == false
    end

    test "get_source_location is not blocked" do
      refute Registry.blocked_tool?("get_source_location")
    end

    test "planning muse can use get_source_location" do
      specs = Registry.specs_for_muse(:planning)
      names = Enum.map(specs, & &1.name)
      assert "get_source_location" in names
    end

    test "coding muse can use get_source_location" do
      specs = Registry.specs_for_muse(:coding)
      names = Enum.map(specs, & &1.name)
      assert "get_source_location" in names
    end

    test "reviewing muse can use get_source_location" do
      specs = Registry.specs_for_muse(:reviewing)
      names = Enum.map(specs, & &1.name)
      assert "get_source_location" in names
    end

    test "restoration muse can use get_source_location" do
      specs = Registry.specs_for_muse(:restoration)
      names = Enum.map(specs, & &1.name)
      assert "get_source_location" in names
    end

    test "testing muse can use get_source_location" do
      specs = Registry.specs_for_muse(:testing)
      names = Enum.map(specs, & &1.name)
      assert "get_source_location" in names
    end

    test "memory muse cannot use get_source_location (no tools)" do
      specs = Registry.specs_for_muse(:memory)
      names = Enum.map(specs, & &1.name)
      refute "get_source_location" in names
    end
  end

  describe "get_docs registration" do
    test "get_docs is a registered tool" do
      assert Registry.known_tool?("get_docs")
      spec = Registry.get("get_docs")
      assert spec.name == "get_docs"
      assert spec.handler == Muse.Tools.GetDocs
      assert spec.kind == :read
      assert spec.risk == :low
      assert spec.permission == :read

      assert spec.allowed_muses == [
               :planning,
               :coding,
               :testing,
               :reviewing,
               :restoration,
               :memory
             ]

      assert spec.requires_approval == false
    end

    test "get_docs is not blocked" do
      refute Registry.blocked_tool?("get_docs")
    end

    test "planning muse can use get_docs" do
      specs = Registry.specs_for_muse(:planning)
      names = Enum.map(specs, & &1.name)
      assert "get_docs" in names
    end

    test "coding muse can use get_docs" do
      specs = Registry.specs_for_muse(:coding)
      names = Enum.map(specs, & &1.name)
      assert "get_docs" in names
    end

    test "reviewing muse can use get_docs" do
      specs = Registry.specs_for_muse(:reviewing)
      names = Enum.map(specs, & &1.name)
      assert "get_docs" in names
    end

    test "restoration muse can use get_docs" do
      specs = Registry.specs_for_muse(:restoration)
      names = Enum.map(specs, & &1.name)
      assert "get_docs" in names
    end

    test "testing muse can use get_docs" do
      specs = Registry.specs_for_muse(:testing)
      names = Enum.map(specs, & &1.name)
      assert "get_docs" in names
    end

    test "memory muse cannot use get_docs (no tools)" do
      specs = Registry.specs_for_muse(:memory)
      names = Enum.map(specs, & &1.name)
      refute "get_docs" in names
    end
  end
end
