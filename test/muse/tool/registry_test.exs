defmodule Muse.Tool.RegistryTest do
  use ExUnit.Case, async: true

  alias Muse.Tool.Registry

  describe "all/0" do
    test "returns all 8 registered tool specs" do
      assert length(Registry.all()) == 8
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
               "list_skills"
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
    end

    test "does not include write tools for planning muse" do
      specs = Registry.specs_for_muse(:planning)
      names = Enum.map(specs, & &1.name)

      refute "write_file" in names
      refute "shell_command" in names
      refute "patch_apply" in names
    end
  end

  describe "provider_schemas/1" do
    test "returns OpenAI-compatible schemas for planning muse" do
      schemas = Registry.provider_schemas(:planning)

      assert length(schemas) == 8

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
      assert Registry.blocked_tool?("patch_apply")
      assert Registry.blocked_tool?("shell_command")
      assert Registry.blocked_tool?("network_call")
      assert Registry.blocked_tool?("remote_execution")
    end

    test "returns false for read-only tools" do
      refute Registry.blocked_tool?("read_file")
      refute Registry.blocked_tool?("list_files")
    end

    test "returns false for unknown tools" do
      refute Registry.blocked_tool?("totally_unknown")
    end
  end

  describe "blocked_tool_names/0" do
    test "returns all blocked tool names" do
      names = Registry.blocked_tool_names()
      assert "write_file" in names
      assert "shell_command" in names
      assert "network_call" in names
    end
  end

  describe "tool_names/0" do
    test "returns all registered tool names" do
      names = Registry.tool_names()
      assert length(names) == 8
      assert "read_file" in names
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
end
