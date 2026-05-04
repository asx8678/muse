defmodule Muse.MuseRegistryTest do
  use ExUnit.Case, async: true

  alias Muse.MuseProfile
  alias Muse.MuseRegistry

  describe "all/0" do
    test "returns all registered profiles" do
      profiles = MuseRegistry.all()

      assert length(profiles) == 2
      assert Enum.all?(profiles, &(%MuseProfile{} = &1))
    end

    test "returns profiles in deterministic order" do
      ids = MuseRegistry.all() |> Enum.map(& &1.id)

      assert ids == [:planning, :coding]
    end

    test "calling all/0 multiple times returns same order" do
      ids1 = MuseRegistry.all() |> Enum.map(& &1.id)
      ids2 = MuseRegistry.all() |> Enum.map(& &1.id)

      assert ids1 == ids2
    end
  end

  describe "ids/0" do
    test "returns profile id atoms in deterministic order" do
      assert MuseRegistry.ids() == [:planning, :coding]
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
      assert length(summaries) == 2
      assert Enum.all?(summaries, &is_map/1)
    end

    test "summaries are in deterministic order" do
      ids = MuseRegistry.summaries() |> Enum.map(& &1.id)

      assert ids == [:planning, :coding]
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
