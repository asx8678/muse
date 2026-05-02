defmodule Muse.BeamStatsTest do
  use ExUnit.Case, async: true

  alias Muse.BeamStats

  describe "snapshot/0" do
    test "returns a map with required keys" do
      snap = BeamStats.snapshot()

      assert is_map(snap)
      assert Map.has_key?(snap, :memory)
      assert Map.has_key?(snap, :total_memory)
      assert Map.has_key?(snap, :process_count)
      assert Map.has_key?(snap, :process_limit)
      assert Map.has_key?(snap, :port_count)
      assert Map.has_key?(snap, :port_limit)
      assert Map.has_key?(snap, :scheduler_count)
      assert Map.has_key?(snap, :schedulers_online)
      assert Map.has_key?(snap, :otp_release)
      assert Map.has_key?(snap, :system_version)
    end

    test "memory map contains standard erlang.memory keys" do
      snap = BeamStats.snapshot()
      memory = snap.memory

      assert is_map(memory)
      assert Map.has_key?(memory, :total)
      assert Map.has_key?(memory, :processes)
      assert Map.has_key?(memory, :binary)
    end

    test "total_memory is a positive integer" do
      snap = BeamStats.snapshot()
      assert is_integer(snap.total_memory)
      assert snap.total_memory > 0
    end

    test "process_count is a positive integer" do
      snap = BeamStats.snapshot()
      assert is_integer(snap.process_count)
      assert snap.process_count > 0
    end

    test "process_limit is a positive integer >= process_count" do
      snap = BeamStats.snapshot()
      assert is_integer(snap.process_limit)
      assert snap.process_limit >= snap.process_count
    end

    test "scheduler_count is a positive integer" do
      snap = BeamStats.snapshot()
      assert is_integer(snap.scheduler_count)
      assert snap.scheduler_count > 0
    end

    test "schedulers_online <= scheduler_count" do
      snap = BeamStats.snapshot()
      assert snap.schedulers_online <= snap.scheduler_count
    end

    test "otp_release is a string" do
      snap = BeamStats.snapshot()
      assert is_binary(snap.otp_release)
    end
  end
end
