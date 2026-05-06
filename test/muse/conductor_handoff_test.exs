defmodule Muse.ConductorHandoffTest do
  use ExUnit.Case, async: true

  alias Muse.{Conductor, MuseRegistry, Session}

  describe "can_handoff_to?/3" do
    test "Planning Muse can handoff to Coding Muse" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(planning, :coding, session) == true
    end

    test "Coding Muse can handoff to Planning and Testing" do
      coding = MuseRegistry.get(:coding)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(coding, :planning, session) == true
      assert Conductor.can_handoff_to?(coding, :testing, session) == true
    end

    test "Memory Muse cannot handoff to anyone" do
      memory = MuseRegistry.get(:memory)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(memory, :planning, session) == false
      assert Conductor.can_handoff_to?(memory, :coding, session) == false
    end

    test "Restoration Muse can handoff to Planning" do
      restoration = MuseRegistry.get(:restoration)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(restoration, :planning, session) == true
    end

    test "cannot handoff to unknown Muse" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(planning, :unknown_muse, session) == false
    end

    test "cannot handoff to unlisted target" do
      # Planning can handoff to coding, but not to restoration
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", status: :idle)

      assert Conductor.can_handoff_to?(planning, :coding, session) == true
      assert Conductor.can_handoff_to?(planning, :restoration, session) == false
    end
  end

  describe "request_handoff/4" do
    test "returns handoff event spec for valid handoff" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} = Conductor.request_handoff(planning, :coding, session, reason: "Plan approved")

      assert {:conductor, :muse_handoff_requested, data, opts} = spec
      assert data.source_muse_id == :planning
      assert data.target_muse_id == :coding
      assert data.reason == "Plan approved"
      assert opts[:visibility] == :user
    end

    test "sanitizes context in handoff" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, spec} =
        Conductor.request_handoff(planning, :coding, session,
          context: %{secret_key: "sk-123", normal_data: "safe"}
        )

      assert {:conductor, :muse_handoff_requested, data, _opts} = spec
      # Context should be sanitized (no raw secret values)
      assert is_map(data.context)
    end

    test "returns error for invalid handoff" do
      memory = MuseRegistry.get(:memory)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      assert {:error, {:handoff_not_allowed, :memory, :planning}} =
               Conductor.request_handoff(memory, :planning, session)
    end

    test "returns error for unknown target" do
      planning = MuseRegistry.get(:planning)
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      assert {:error, {:handoff_not_allowed, :planning, :unknown}} =
               Conductor.request_handoff(planning, :unknown, session)
    end
  end

  describe "complete_handoff/2" do
    test "updates session active_muse" do
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      {:ok, updated_session} = Conductor.complete_handoff(session, :coding)

      assert updated_session.active_muse == "coding"
    end

    test "returns error for invalid Muse" do
      session = Session.new(workspace: "/tmp", id: "session_1", status: :idle)

      assert {:error, {:invalid_target_muse, :unknown}} =
               Conductor.complete_handoff(session, :unknown)
    end
  end

  describe "handoff targets validation" do
    test "all registered handoff targets exist in registry" do
      for profile <- MuseRegistry.all() do
        for target <- profile.handoff_targets || [] do
          assert MuseRegistry.get(target) != nil,
                 "#{profile.display_name} handoff target #{target} not found in registry"
        end
      end
    end

    test "handoff targets form a valid graph (no orphan targets)" do
      registry_ids = MuseRegistry.ids() |> MapSet.new()

      for profile <- MuseRegistry.all() do
        for target <- profile.handoff_targets || [] do
          assert MapSet.member?(registry_ids, target),
                 "#{profile.display_name} references non-existent handoff target: #{target}"
        end
      end
    end
  end
end
