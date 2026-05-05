defmodule Muse.RepairPolicyTest do
  use ExUnit.Case, async: true

  alias Muse.RepairPolicy

  describe "new/1" do
    test "creates policy with default max_repairs of 2" do
      policy = RepairPolicy.new()
      assert policy.max_repairs == 2
      assert policy.attempts == 0
    end

    test "accepts custom max_repairs within ceiling" do
      policy = RepairPolicy.new(max_repairs: 4)
      assert policy.max_repairs == 4
    end

    test "clamps max_repairs to absolute ceiling of 5" do
      policy = RepairPolicy.new(max_repairs: 100)
      assert policy.max_repairs == 5
    end

    test "clamps max_repairs to minimum of 1" do
      policy = RepairPolicy.new(max_repairs: 0)
      assert policy.max_repairs == 1
    end

    test "accepts session_id" do
      policy = RepairPolicy.new(session_id: "sess_123")
      assert policy.session_id == "sess_123"
    end

    test "session_id defaults to nil" do
      policy = RepairPolicy.new()
      assert policy.session_id == nil
    end
  end

  describe "allow?/1" do
    test "allows repair when budget is not exhausted" do
      policy = RepairPolicy.new(max_repairs: 2)
      assert RepairPolicy.allow?(policy) == true
    end

    test "denies repair when budget is exhausted" do
      policy = RepairPolicy.new(max_repairs: 1)
      {:ok, policy} = RepairPolicy.record(policy)
      assert RepairPolicy.allow?(policy) == false
    end
  end

  describe "record/1" do
    test "increments attempt counter" do
      policy = RepairPolicy.new(max_repairs: 3)
      {:ok, p1} = RepairPolicy.record(policy)
      assert p1.attempts == 1

      {:ok, p2} = RepairPolicy.record(p1)
      assert p2.attempts == 2

      {:ok, p3} = RepairPolicy.record(p2)
      assert p3.attempts == 3
    end

    test "returns error when budget exhausted" do
      policy = RepairPolicy.new(max_repairs: 1)
      {:ok, p1} = RepairPolicy.record(policy)

      result = RepairPolicy.record(p1)
      assert result == {:error, :repair_budget_exhausted}
    end

    test "preserves max_repairs and session_id" do
      policy = RepairPolicy.new(max_repairs: 2, session_id: "sess_1")
      {:ok, p1} = RepairPolicy.record(policy)
      assert p1.max_repairs == 2
      assert p1.session_id == "sess_1"
    end

    test "proves repair loop cannot become autonomous" do
      # Simulate a repair loop that tries to exceed the budget
      policy = RepairPolicy.new(max_repairs: 2)

      results =
        1..10
        |> Enum.reduce({policy, []}, fn _, {p, acc} ->
          case RepairPolicy.record(p) do
            {:ok, updated} -> {updated, [:allowed | acc]}
            {:error, _} -> {p, [:denied | acc]}
          end
        end)
        |> elem(1)
        |> Enum.reverse()

      # Only first 2 attempts should be allowed
      assert Enum.count(results, &(&1 == :allowed)) == 2
      assert Enum.count(results, &(&1 == :denied)) == 8
    end
  end

  describe "remaining/1" do
    test "returns initial budget when no attempts" do
      policy = RepairPolicy.new(max_repairs: 3)
      assert RepairPolicy.remaining(policy) == 3
    end

    test "decrements after each attempt" do
      policy = RepairPolicy.new(max_repairs: 3)
      {:ok, p1} = RepairPolicy.record(policy)
      assert RepairPolicy.remaining(p1) == 2

      {:ok, p2} = RepairPolicy.record(p1)
      assert RepairPolicy.remaining(p2) == 1

      {:ok, p3} = RepairPolicy.record(p2)
      assert RepairPolicy.remaining(p3) == 0
    end

    test "returns 0 when exhausted" do
      policy = RepairPolicy.new(max_repairs: 1)
      {:ok, p1} = RepairPolicy.record(policy)
      assert RepairPolicy.remaining(p1) == 0
    end
  end

  describe "exhausted?/1" do
    test "returns false when budget remains" do
      policy = RepairPolicy.new(max_repairs: 2)
      refute RepairPolicy.exhausted?(policy)
    end

    test "returns true when budget exhausted" do
      policy = RepairPolicy.new(max_repairs: 1)
      {:ok, p1} = RepairPolicy.record(policy)
      assert RepairPolicy.exhausted?(p1)
    end
  end

  describe "absolute_max/0" do
    test "returns 5" do
      assert RepairPolicy.absolute_max() == 5
    end
  end

  describe "default_max/0" do
    test "returns 2" do
      assert RepairPolicy.default_max() == 2
    end
  end

  describe "cannot override absolute ceiling" do
    test "even with very high max_repairs" do
      policy = RepairPolicy.new(max_repairs: 1000)
      assert policy.max_repairs == 5

      # All 5 repairs allowed
      policy =
        Enum.reduce(1..5, policy, fn _, p ->
          {:ok, updated} = RepairPolicy.record(p)
          updated
        end)

      # 6th is denied
      assert RepairPolicy.record(policy) == {:error, :repair_budget_exhausted}
    end
  end
end
