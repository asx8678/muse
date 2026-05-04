defmodule Muse.MuseProfileTest do
  use ExUnit.Case, async: true

  alias Muse.MuseProfile

  describe "struct enforcement" do
    test "requires enforced keys: id, display_name, role, prompt, tools" do
      assert_raise ArgumentError, ~r/keys must also be given.*:id/, fn ->
        MuseProfile.new!(display_name: "X", role: :x, prompt: "p", tools: [])
      end

      assert_raise ArgumentError, ~r/keys must also be given.*:display_name/, fn ->
        MuseProfile.new!(id: :x, role: :x, prompt: "p", tools: [])
      end

      assert_raise ArgumentError, ~r/keys must also be given.*:role/, fn ->
        MuseProfile.new!(id: :x, display_name: "X", prompt: "p", tools: [])
      end

      assert_raise ArgumentError, ~r/keys must also be given.*:prompt/, fn ->
        MuseProfile.new!(id: :x, display_name: "X", role: :x, tools: [])
      end

      assert_raise ArgumentError, ~r/keys must also be given.*:tools/, fn ->
        MuseProfile.new!(id: :x, display_name: "X", role: :x, prompt: "p")
      end
    end

    test "creates profile when all enforced keys present" do
      profile =
        MuseProfile.new!(
          id: :test,
          display_name: "Test Muse",
          role: :test,
          prompt: "You are a test muse.",
          tools: ["read_file"]
        )

      assert %MuseProfile{} = profile
      assert profile.id == :test
      assert profile.display_name == "Test Muse"
      assert profile.role == :test
      assert profile.prompt == "You are a test muse."
      assert profile.tools == ["read_file"]
    end

    test "accepts keyword list input" do
      profile =
        MuseProfile.new!(
          id: :test,
          display_name: "Test Muse",
          role: :test,
          prompt: "p",
          tools: []
        )

      assert profile.id == :test
    end

    test "accepts map input" do
      profile =
        MuseProfile.new!(%{
          id: :test,
          display_name: "Test Muse",
          role: :test,
          prompt: "p",
          tools: []
        })

      assert profile.id == :test
    end
  end

  describe "no :name field" do
    test "struct does not have a :name key" do
      profile =
        MuseProfile.new!(
          id: :test,
          display_name: "Test Muse",
          role: :test,
          prompt: "p",
          tools: []
        )

      assert Map.has_key?(profile, :name) == false
    end

    test "setting :name in new!/1 is silently dropped" do
      profile =
        MuseProfile.new!(
          id: :test,
          display_name: "Test Muse",
          role: :test,
          prompt: "p",
          tools: [],
          name: "should be dropped"
        )

      # :name is not a struct field, so it should not appear in the map
      assert Map.has_key?(profile, :name) == false
    end
  end

  describe "optional fields" do
    test "defaults style to empty map" do
      profile =
        MuseProfile.new!(
          id: :test,
          display_name: "Test Muse",
          role: :test,
          prompt: "p",
          tools: []
        )

      assert profile.style == %{}
    end

    test "optional fields default to nil" do
      profile =
        MuseProfile.new!(
          id: :test,
          display_name: "Test Muse",
          role: :test,
          prompt: "p",
          tools: []
        )

      assert profile.description == nil
      assert profile.system_prompt == nil
      assert profile.allowed_tools == nil
      assert profile.default_model == nil
      assert profile.output_schema == nil
      assert profile.response_mode == nil
      assert profile.permissions == nil
      assert profile.handoff_targets == nil
      assert profile.can_write? == nil
      assert profile.requires_plan_approval? == nil
    end

    test "all fields can be set via new!/1" do
      profile =
        MuseProfile.new!(
          id: :test,
          display_name: "Test Muse",
          description: "A test profile",
          role: :test,
          prompt: "p",
          system_prompt: "system",
          tools: ["read_file"],
          allowed_tools: ["read_file", "write_file"],
          default_model: "gpt-4",
          output_schema: Muse.Plan,
          response_mode: :plan,
          permissions: %{read: true, write: false},
          handoff_targets: [:other],
          can_write?: true,
          requires_plan_approval?: true,
          style: %{tone: "friendly"}
        )

      assert profile.description == "A test profile"
      assert profile.system_prompt == "system"
      assert profile.allowed_tools == ["read_file", "write_file"]
      assert profile.default_model == "gpt-4"
      assert profile.output_schema == Muse.Plan
      assert profile.response_mode == :plan
      assert profile.permissions == %{read: true, write: false}
      assert profile.handoff_targets == [:other]
      assert profile.can_write? == true
      assert profile.requires_plan_approval? == true
      assert profile.style == %{tone: "friendly"}
    end
  end

  describe "summary/1" do
    test "returns map with selected public fields" do
      profile =
        MuseProfile.new!(
          id: :planning,
          display_name: "Planning Muse",
          description: "Plans things",
          role: :planning,
          prompt: "p",
          tools: ["read_file"],
          permissions: %{read: true}
        )

      summary = MuseProfile.summary(profile)

      assert summary.id == :planning
      assert summary.display_name == "Planning Muse"
      assert summary.role == :planning
      assert summary.description == "Plans things"
      assert summary.tools == ["read_file"]
      assert summary.permissions == %{read: true}
    end

    test "summary does not include :name key" do
      profile =
        MuseProfile.new!(
          id: :test,
          display_name: "Test Muse",
          role: :test,
          prompt: "p",
          tools: []
        )

      summary = MuseProfile.summary(profile)

      assert Map.has_key?(summary, :name) == false
    end

    test "summary uses Muse-first display_name" do
      profile =
        MuseProfile.new!(
          id: :planning,
          display_name: "Planning Muse",
          role: :planning,
          prompt: "p",
          tools: []
        )

      summary = MuseProfile.summary(profile)

      assert summary.display_name == "Planning Muse"
      refute summary.display_name =~ ~r/\bAgent\b/i
      refute summary.display_name =~ ~r/\bBot\b/i
    end

    test "summary does not leak internal fields" do
      profile =
        MuseProfile.new!(
          id: :test,
          display_name: "Test Muse",
          role: :test,
          prompt: "secret prompt text",
          system_prompt: "secret system prompt",
          tools: []
        )

      summary = MuseProfile.summary(profile)

      refute Map.has_key?(summary, :prompt)
      refute Map.has_key?(summary, :system_prompt)
      refute Map.has_key?(summary, :handoff_targets)
      refute Map.has_key?(summary, :style)
    end
  end
end
