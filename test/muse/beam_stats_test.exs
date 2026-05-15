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
      assert Map.has_key?(snap, :run_queue)
      assert Map.has_key?(snap, :otp_release)
      assert Map.has_key?(snap, :system_version)
      assert Map.has_key?(snap, :atoms)
      assert Map.has_key?(snap, :atom_limit)
      assert Map.has_key?(snap, :ets_count)
      assert Map.has_key?(snap, :loaded_modules)
      assert Map.has_key?(snap, :uptime_ms)
      assert Map.has_key?(snap, :logical_processors)
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

    # Note: :process_limit, :scheduler_count, :schedulers_online, :port_count, :port_limit
    # were removed from BeamStats.snapshot/0 for cross-platform reliability and to avoid
    # privileged or expensive system_info calls. The tests below were retired.

    test "otp_release is a string" do
      snap = BeamStats.snapshot()
      assert is_binary(snap.otp_release)
    end
  end
end
