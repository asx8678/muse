defmodule Muse.MuseRegistryTest do
  use ExUnit.Case, async: true

  alias Muse.MuseProfile
  alias Muse.MuseRegistry

  describe "all/0" do
    test "returns all registered profiles" do
      profiles = MuseRegistry.all()

      assert length(profiles) == 4
      assert Enum.all?(profiles, &(%MuseProfile{} = &1))
    end

    test "returns profiles in deterministic order" do
      ids = MuseRegistry.all() |> Enum.map(& &1.id)

      assert ids == [:planning, :coding, :reviewing, :testing]
    end

    test "calling all/0 multiple times returns same order" do
      ids1 = MuseRegistry.all() |> Enum.map(& &1.id)
      ids2 = MuseRegistry.all() |> Enum.map(& &1.id)

      assert ids1 == ids2
    end
  end

  describe "ids/0" do
    test "returns profile id atoms in deterministic order" do
      assert MuseRegistry.ids() == [:planning, :coding, :reviewing, :testing]
    end
  end

  describe "get/1" do
    test "returns profile by atom id" do
      profile = MuseRegistry.get(:planning)

      assert %MuseProfile{} = profile
      assert profile.id == :planning
      assert profile.display_name == "Planning Muse"
    end

    test "returns profile by string id" do
      profile = MuseRegistry.get("planning")

      assert profile.id == :planning
    end

    test "returns coding muse by atom" do
      profile = MuseRegistry.get(:coding)

      assert profile.id == :coding
      assert profile.display_name == "Coding Muse"
    end

    test "returns coding muse by string" do
      profile = MuseRegistry.get("coding")

      assert profile.id == :coding
    end

    test "returns nil for unknown atom" do
      assert MuseRegistry.get(:unknown) == nil
    end

    test "returns nil for unknown string" do
      assert MuseRegistry.get("nonexistent_muse") == nil
    end
  end

  describe "fetch/1" do
    test "returns {:ok, profile} for known atom" do
      assert {:ok, profile} = MuseRegistry.fetch(:planning)
      assert profile.id == :planning
    end

    test "returns {:ok, profile} for known string" do
      assert {:ok, profile} = MuseRegistry.fetch("coding")
      assert profile.id == :coding
    end

    test "returns {:error, :not_found} for unknown atom" do
      assert MuseRegistry.fetch(:unknown) == {:error, :not_found}
    end

    test "returns {:error, :not_found} for unknown string" do
      assert MuseRegistry.fetch("nonexistent_muse") == {:error, :not_found}
    end
  end

  describe "summaries/0" do
    test "returns list of maps" do
      summaries = MuseRegistry.summaries()

      assert is_list(summaries)
      assert length(summaries) == 4
      assert Enum.all?(summaries, &is_map/1)
    end

    test "summaries are in deterministic order" do
      ids = MuseRegistry.summaries() |> Enum.map(& &1.id)

      assert ids == [:planning, :coding, :reviewing, :testing]
    end

    test "summaries contain expected keys" do
      summary = hd(MuseRegistry.summaries())

      assert Map.has_key?(summary, :id)
      assert Map.has_key?(summary, :display_name)
      assert Map.has_key?(summary, :role)
      assert Map.has_key?(summary, :description)
      assert Map.has_key?(summary, :tools)
      assert Map.has_key?(summary, :permissions)
    end

    test "summaries do not contain :name key" do
      summaries = MuseRegistry.summaries()

      for summary <- summaries do
        refute Map.has_key?(summary, :name)
      end
    end

    test "summaries use Muse-first display names" do
      for summary <- MuseRegistry.summaries() do
        assert summary.display_name =~ "Muse"
        refute summary.display_name =~ ~r/\bAgent\b/i
        refute summary.display_name =~ ~r/\bBot\b/i
      end
    end

    test "summaries do not leak internal fields" do
      for summary <- MuseRegistry.summaries() do
        refute Map.has_key?(summary, :prompt)
        refute Map.has_key?(summary, :system_prompt)
        refute Map.has_key?(summary, :handoff_targets)
        refute Map.has_key?(summary, :style)
      end
    end
  end

  describe "Planning Muse profile" do
    setup do
      {:ok, planning: MuseRegistry.get(:planning)}
    end

    test "has correct identity fields", %{planning: planning} do
      assert planning.id == :planning
      assert planning.display_name == "Planning Muse"
      assert planning.role == :planning

      assert planning.description ==
               "Inspects the workspace and creates approval-gated implementation plans."
    end

    test "has no write/shell/network permissions", %{planning: planning} do
      assert planning.permissions.read == true
      assert planning.permissions.write == false
      assert planning.permissions.shell == false
      assert planning.permissions.network == false
    end

    test "can create plans but cannot execute them", %{planning: planning} do
      assert planning.permissions.can_create_plan == true
      assert planning.permissions.can_execute_plan == false
    end

    test "cannot write and does not require plan approval", %{planning: planning} do
      assert planning.can_write? == false
      assert planning.requires_plan_approval? == false
    end

    test "has read-only tools", %{planning: planning} do
      assert "list_files" in planning.tools
      assert "read_file" in planning.tools
      assert "repo_search" in planning.tools
      assert "git_status" in planning.tools
      assert "git_diff_readonly" in planning.tools
      assert "ask_user_question" in planning.tools
      assert "list_muses" in planning.tools
      assert "list_skills" in planning.tools
    end

    test "has exactly the M1 read-only planning tool surface", %{planning: planning} do
      assert MapSet.new(planning.tools) ==
               MapSet.new([
                 "list_files",
                 "read_file",
                 "repo_search",
                 "git_status",
                 "git_diff_readonly",
                 "ask_user_question",
                 "list_muses",
                 "list_skills"
               ])
    end

    test "has no write tools", %{planning: planning} do
      refute "patch_propose" in planning.tools
      refute "patch_apply" in planning.tools
      refute "test_runner" in planning.tools
    end

    test "response mode is :plan", %{planning: planning} do
      assert planning.response_mode == :plan
    end

    test "output schema references Muse.Plan", %{planning: planning} do
      assert planning.output_schema == Muse.Plan
    end

    test "has no :name field", %{planning: planning} do
      refute Map.has_key?(planning, :name)
    end

    test "prompt explicitly requires read-only inspection", %{planning: planning} do
      prompt = planning.prompt
      assert prompt =~ ~r/read.only/i
      assert prompt =~ ~r/inspect/i
    end

    test "prompt explicitly requires structured plan JSON matching PlanSchema", %{
      planning: planning
    } do
      prompt = planning.prompt
      assert prompt =~ ~r/structured plan/i
      assert prompt =~ ~r/JSON/i
      assert prompt =~ ~r/objective/
      assert prompt =~ ~r/tasks/
    end

    test "prompt states that the plan must be approved before implementation", %{
      planning: planning
    } do
      assert planning.prompt =~ ~r/approval/i or planning.prompt =~ ~r/approved/i
    end

    test "prompt forbids writing code, modifying files, or executing commands", %{
      planning: planning
    } do
      prompt = planning.prompt
      # Should explicitly prohibit write/execute actions
      assert prompt =~ ~r/do not write/i or prompt =~ ~r/never.*write/i or
               prompt =~ ~r/not.*write/i
    end

    test "no write/shell/network tool names leak into profile tools", %{planning: planning} do
      blocked = Muse.Tool.Registry.blocked_tool_names()

      for tool <- planning.tools do
        refute tool in blocked
      end
    end
  end

  describe "Coding Muse profile" do
    setup do
      {:ok, coding: MuseRegistry.get(:coding)}
    end

    test "has correct identity fields", %{coding: coding} do
      assert coding.id == :coding
      assert coding.display_name == "Coding Muse"
      assert coding.role == :coding
      assert coding.description == "Implements approved plans by proposing and applying patches."
    end

    test "requires plan approval before write", %{coding: coding} do
      assert coding.requires_plan_approval? == true
    end

    test "can write", %{coding: coding} do
      assert coding.can_write? == true
    end

    test "write and shell require approval", %{coding: coding} do
      assert coding.permissions.write == :approval_required
      assert coding.permissions.shell == :approval_required
    end

    test "no network access", %{coding: coding} do
      assert coding.permissions.network == false
    end

    test "can execute plans but cannot create them", %{coding: coding} do
      assert coding.permissions.can_execute_plan == true
      assert coding.permissions.can_create_plan == false
    end

    test "has write/execution tools", %{coding: coding} do
      assert "patch_propose" in coding.tools
      assert "patch_apply" in coding.tools
      assert "test_runner" in coding.tools
    end

    test "also has read tools", %{coding: coding} do
      assert "list_files" in coding.tools
      assert "read_file" in coding.tools
      assert "repo_search" in coding.tools
      assert "git_status" in coding.tools
      assert "git_diff_readonly" in coding.tools
    end

    test "response mode is :patch", %{coding: coding} do
      assert coding.response_mode == :patch
    end

    test "has no :name field", %{coding: coding} do
      refute Map.has_key?(coding, :name)
    end
  end

  describe "Reviewing Muse profile (PR19)" do
    setup do
      {:ok, reviewing: MuseRegistry.get(:reviewing)}
    end

    test "has correct identity fields", %{reviewing: reviewing} do
      assert reviewing.id == :reviewing
      assert reviewing.display_name == "Reviewing Muse"
      assert reviewing.role == :review
      assert reviewing.description =~ "findings"
    end

    test "has read-only tools only", %{reviewing: reviewing} do
      assert "read_file" in reviewing.tools
      assert "repo_search" in reviewing.tools
      assert "git_status" in reviewing.tools
      assert "git_diff_readonly" in reviewing.tools
    end

    test "has no write/shell/test tools", %{reviewing: reviewing} do
      refute "patch_propose" in reviewing.tools
      refute "patch_apply" in reviewing.tools
      refute "test_runner" in reviewing.tools
      refute "write_file" in reviewing.tools
      refute "shell_command" in reviewing.tools
    end

    test "has no write/shell/network permissions", %{reviewing: reviewing} do
      assert reviewing.permissions.read == true
      assert reviewing.permissions.write == false
      assert reviewing.permissions.shell == false
      assert reviewing.permissions.network == false
    end

    test "cannot write", %{reviewing: reviewing} do
      assert reviewing.can_write? == false
    end

    test "response mode is :text", %{reviewing: reviewing} do
      assert reviewing.response_mode == :text
    end

    test "has no :name field", %{reviewing: reviewing} do
      refute Map.has_key?(reviewing, :name)
    end

    test "prompt mentions review/findings", %{reviewing: reviewing} do
      assert reviewing.prompt =~ ~r/review/i
      assert reviewing.prompt =~ ~r/findings/i or reviewing.prompt =~ ~r/finding/i
    end

    test "display name uses Muse-first language", %{reviewing: reviewing} do
      assert reviewing.display_name =~ "Muse"
      refute reviewing.display_name =~ ~r/\bAgent\b/i
      refute reviewing.display_name =~ ~r/\bBot\b/i
    end

    test "handoff targets are valid muse ids", %{reviewing: reviewing} do
      for target <- reviewing.handoff_targets do
        assert MuseRegistry.get(target) != nil
      end
    end
  end

  describe "Testing Muse profile (PR19)" do
    setup do
      {:ok, testing: MuseRegistry.get(:testing)}
    end

    test "has correct identity fields", %{testing: testing} do
      assert testing.id == :testing
      assert testing.display_name == "Testing Muse"
      assert testing.role == :testing
      assert testing.description =~ "verification"
    end

    test "has read tools plus test_runner", %{testing: testing} do
      assert "read_file" in testing.tools
      assert "repo_search" in testing.tools
      assert "git_status" in testing.tools
      assert "test_runner" in testing.tools
    end

    test "has no write/patch tools", %{testing: testing} do
      refute "patch_propose" in testing.tools
      refute "patch_apply" in testing.tools
      refute "list_files" in testing.tools
      refute "write_file" in testing.tools
    end

    test "permissions are read + approval-required shell, no write/network", %{testing: testing} do
      assert testing.permissions.read == true
      assert testing.permissions.write == false
      assert testing.permissions.shell == :approval_required
      assert testing.permissions.network == false
    end

    test "cannot write", %{testing: testing} do
      assert testing.can_write? == false
    end

    test "response mode is :text", %{testing: testing} do
      assert testing.response_mode == :text
    end

    test "has no :name field", %{testing: testing} do
      refute Map.has_key?(testing, :name)
    end

    test "prompt mentions verification/safe test commands", %{testing: testing} do
      assert testing.prompt =~ ~r/verification/i or testing.prompt =~ ~r/verif/i
      assert testing.prompt =~ ~r/safe/i or testing.prompt =~ ~r/predefined/i
    end

    test "display name uses Muse-first language", %{testing: testing} do
      assert testing.display_name =~ "Muse"
      refute testing.display_name =~ ~r/\bAgent\b/i
      refute testing.display_name =~ ~r/\bBot\b/i
    end

    test "handoff targets are valid muse ids", %{testing: testing} do
      for target <- testing.handoff_targets do
        assert MuseRegistry.get(target) != nil
      end
    end
  end

  describe "profile isolation" do
    test "no profile has a :name field" do
      for profile <- MuseRegistry.all() do
        refute Map.has_key?(profile, :name)
      end
    end

    test "no profile display_name contains Agent or Bot" do
      for profile <- MuseRegistry.all() do
        refute profile.display_name =~ ~r/\bAgent\b/i
        refute profile.display_name =~ ~r/\bBot\b/i
      end
    end

    test "all profiles have non-empty prompt" do
      for profile <- MuseRegistry.all() do
        assert is_binary(profile.prompt)
        assert profile.prompt != ""
      end
    end

    test "all profiles have non-empty tools list" do
      for profile <- MuseRegistry.all() do
        assert is_list(profile.tools)
        assert length(profile.tools) > 0
      end
    end

    test "all profiles have permissions map" do
      for profile <- MuseRegistry.all() do
        assert is_map(profile.permissions)
        assert Map.has_key?(profile.permissions, :read)
        assert Map.has_key?(profile.permissions, :write)
      end
    end
  end
end
