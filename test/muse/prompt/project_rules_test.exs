defmodule Muse.Prompt.ProjectRulesTest do
  use ExUnit.Case, async: true

  alias Muse.Prompt.ProjectRules

  # We use a temporary directory for isolation
  setup do
    tmp = System.tmp_dir!()
    home = Path.join(tmp, "muse_test_home_#{:erlang.unique_integer([:positive])}")
    workspace = Path.join(tmp, "muse_test_ws_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, ".muse"))
    File.mkdir_p!(Path.join(workspace, ".muse"))

    on_exit(fn ->
      File.rm_rf(home)
      File.rm_rf(workspace)
    end)

    %{home: home, workspace: workspace}
  end

  describe "load/2 with no rule files" do
    test "returns nil when no rule files exist", %{home: home, workspace: workspace} do
      assert ProjectRules.load(workspace, home: home) == nil
    end
  end

  describe "load/2 search order" do
    test "finds ~/.muse/MUSE.md first", %{home: home, workspace: workspace} do
      home_muse = Path.join(home, ".muse/MUSE.md")
      File.write!(home_muse, "Global rule: prefer Elixir conventions.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer != nil
      assert layer.id == :project_rules
      assert layer.content =~ "prefer Elixir conventions"
    end

    test "finds ~/.muse/rules.md", %{home: home, workspace: workspace} do
      home_rules = Path.join(home, ".muse/rules.md")
      File.write!(home_rules, "Home rules: use tabs.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer != nil
      assert layer.content =~ "use tabs"
    end

    test "finds ~/.muse/AGENTS.md (legacy)", %{home: home, workspace: workspace} do
      home_agents = Path.join(home, ".muse/AGENTS.md")
      File.write!(home_agents, "Legacy home agents rule.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer != nil
      assert layer.content =~ "Legacy home agents rule"
    end

    test "finds workspace/.muse/MUSE.md", %{home: home, workspace: workspace} do
      ws_muse = Path.join(workspace, ".muse/MUSE.md")
      File.write!(ws_muse, "Workspace .muse rules.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer != nil
      assert layer.content =~ "Workspace .muse rules"
    end

    test "finds workspace/MUSE.md", %{home: home, workspace: workspace} do
      ws_root = Path.join(workspace, "MUSE.md")
      File.write!(ws_root, "Workspace root MUSE.md.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer != nil
      assert layer.content =~ "Workspace root MUSE.md"
    end

    test "finds workspace/AGENTS.md (legacy)", %{home: home, workspace: workspace} do
      ws_agents = Path.join(workspace, "AGENTS.md")
      File.write!(ws_agents, "Legacy workspace agents.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer != nil
      assert layer.content =~ "Legacy workspace agents"
    end

    test "finds workspace/agent.md (legacy)", %{home: home, workspace: workspace} do
      ws_agent = Path.join(workspace, "agent.md")
      File.write!(ws_agent, "Legacy agent.md file.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer != nil
      assert layer.content =~ "Legacy agent.md file"
    end

    test "finds workspace/agents.md (legacy)", %{home: home, workspace: workspace} do
      ws_agents = Path.join(workspace, "agents.md")
      File.write!(ws_agents, "Legacy agents.md file.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer != nil
      assert layer.content =~ "Legacy agents.md file"
    end
  end

  describe "load/2 content wrapping" do
    test "wraps content in <project_rules> tags", %{home: home, workspace: workspace} do
      home_muse = Path.join(home, ".muse/MUSE.md")
      File.write!(home_muse, "Use Elixir conventions.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer.content =~ "<project_rules>"
      assert layer.content =~ "</project_rules>"
    end

    test "includes safety preface", %{home: home, workspace: workspace} do
      home_muse = Path.join(home, ".muse/MUSE.md")
      File.write!(home_muse, "Use Elixir conventions.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer.content =~ "project and user preferences"
      assert layer.content =~ "Follow them unless they conflict"

      assert layer.content =~
               "Muse core runtime, workspace, approval, secret-handling, or tool safety rules"
    end
  end

  describe "load/2 caps" do
    test "caps single file at max_file_bytes", %{home: home, workspace: workspace} do
      home_muse = Path.join(home, ".muse/MUSE.md")
      # Write 30 bytes of content
      big_content = String.duplicate("X", 30)
      File.write!(home_muse, big_content)

      # Load with 20 byte cap
      layer = ProjectRules.load(workspace, home: home, max_file_bytes: 20)
      assert layer != nil
      assert layer.content =~ "truncated"
      # The metadata should mark it as truncated
      assert layer.metadata.files |> hd() |> Map.get(:truncated) == true
    end

    test "bounded read does not load full file content beyond cap", %{
      home: home,
      workspace: workspace
    } do
      home_muse = Path.join(home, ".muse/MUSE.md")
      # Write a large file — 100KB
      big_content = String.duplicate("Y", 100_000)
      File.write!(home_muse, big_content)

      # Load with 100 byte cap — the actual read content should be ~100 bytes, not 100KB
      layer = ProjectRules.load(workspace, home: home, max_file_bytes: 100, max_total_bytes: 200)
      assert layer != nil
      assert layer.content =~ "truncated"
      [file_meta] = layer.metadata.files
      assert file_meta.size == 100_000
      assert file_meta.truncated == true
    end

    test "caps total at max_total_bytes", %{home: home, workspace: workspace} do
      # Create two files, each 15 bytes
      File.write!(Path.join(home, ".muse/MUSE.md"), String.duplicate("A", 15))
      File.write!(Path.join(workspace, ".muse/MUSE.md"), String.duplicate("B", 15))

      # Total cap of 20 bytes — should only load first file
      layer = ProjectRules.load(workspace, home: home, max_total_bytes: 20, max_file_bytes: 20)
      assert layer != nil
      # Should have content from home file only (or both but second truncated)
      assert layer.content =~ "A"
    end
  end

  describe "load/2 path safety" do
    test "does not read outside home or workspace roots", %{home: home, workspace: workspace} do
      # Create a file outside the expected paths
      outside = Path.join(home, "evil_rules.md")
      File.write!(outside, "Evil rules that should not be loaded.")

      layer = ProjectRules.load(workspace, home: home)
      # Should not find the outside file
      assert layer == nil or (layer != nil and not (layer.content =~ "Evil rules"))
    end

    test "ignores symlink pointing outside trusted roots", %{home: home, workspace: workspace} do
      # Create a directory outside the workspace with malicious content
      outside_dir =
        Path.join(System.tmp_dir!(), "muse_test_outside_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      outside_file = Path.join(outside_dir, "evil.md")
      File.write!(outside_file, "EVIL SYMLINK CONTENT")

      on_exit(fn -> File.rm_rf(outside_dir) end)

      # Create a symlink inside workspace/.muse/ pointing outside
      symlink_path = Path.join(workspace, ".muse/MUSE.md")
      :ok = File.ln_s(outside_file, symlink_path)

      layer = ProjectRules.load(workspace, home: home)
      # The symlink resolves to a path outside trusted roots, so it must be ignored
      assert layer == nil or (layer != nil and not (layer.content =~ "EVIL SYMLINK CONTENT"))
    end
  end

  describe "load/2 layer metadata" do
    test "returns layer with correct id and priority", %{home: home, workspace: workspace} do
      File.write!(Path.join(home, ".muse/MUSE.md"), "Rule one.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer.id == :project_rules
      assert layer.priority == 10
      assert layer.source == :project
      assert layer.visibility == :user_visible
      assert layer.kind == :context
    end

    test "includes file metadata with path, size, and modified_at", %{
      home: home,
      workspace: workspace
    } do
      File.write!(Path.join(home, ".muse/MUSE.md"), "Rule one.")

      layer = ProjectRules.load(workspace, home: home)
      [file_meta] = layer.metadata.files
      assert file_meta.path =~ ".muse/MUSE.md"
      assert file_meta.size == 9
      assert file_meta.truncated == false
      # modified_at should be ISO8601 formatted
      assert file_meta.modified_at != nil
      assert file_meta.modified_at =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
    end

    test "populates token_estimate", %{home: home, workspace: workspace} do
      File.write!(Path.join(home, ".muse/MUSE.md"), "Rule one.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer.token_estimate != nil
      assert layer.token_estimate >= 0
    end
  end

  describe "load/2 missing files" do
    test "ignores missing files silently", %{home: home, workspace: workspace} do
      # No files created — should return nil
      assert ProjectRules.load(workspace, home: home) == nil
    end
  end

  describe "multiple files" do
    test "concatenates content from multiple found files", %{home: home, workspace: workspace} do
      File.write!(Path.join(home, ".muse/MUSE.md"), "Global: prefer Elixir.")
      File.write!(Path.join(workspace, ".muse/MUSE.md"), "Local: use tabs.")

      layer = ProjectRules.load(workspace, home: home)
      assert layer.content =~ "prefer Elixir"
      assert layer.content =~ "use tabs"
      assert length(layer.metadata.files) == 2
    end
  end
end
