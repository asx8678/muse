defmodule Muse.BeamStats do
  @moduledoc """
  Runtime BEAM statistics snapshot.

  Returns a plain map with memory, process, scheduler, and OTP info.
  All values are gathered synchronously; each sub-call is rescued so a
  single failing metric cannot take down the snapshot.
  """

  @cpu_sample_key :muse_cpu_samples

  @spec snapshot() :: map()
  def snapshot do
    %{
      memory: safe_memory(),
      total_memory: safe_total_memory(),
      otp_release: safe_otp_release(),
      system_version: safe_system_version(),
      atoms: safe_atom_count(),
      atom_limit: safe_atom_limit(),
      ets_count: safe_ets_count(),
      loaded_modules: safe_loaded_modules(),
      uptime_ms: safe_uptime_ms(),
      run_queue: safe_run_queue(),
      gc_count: safe_gc_count(),
      gc_words_reclaimed: safe_gc_words_reclaimed(),
      logical_processors: safe_logical_processors(),
      process_count: safe_process_count(),
      system_architecture: safe_system_architecture(),
      cpu_current: safe_cpu_current(),
      cpu_hourly_avg: safe_cpu_hourly_avg()
    }
  end

  defp safe_memory do
    try do
      :erlang.memory() |> Enum.into(%{})
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  defp safe_total_memory do
    try do
      :erlang.memory(:total)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_otp_release do
    try do
      to_string(:erlang.system_info(:otp_release))
    rescue
      _ -> "unknown"
    catch
      _, _ -> "unknown"
    end
  end

  defp safe_system_version do
    try do
      to_string(:erlang.system_info(:system_version))
    rescue
      _ -> "unknown"
    catch
      _, _ -> "unknown"
    end
  end

  defp safe_atom_count do
    try do
      :erlang.system_info(:atom_count)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_atom_limit do
    try do
      :erlang.system_info(:atom_limit)
    rescue
      _ -> 1
    catch
      _, _ -> 1
    end
  end

  defp safe_ets_count do
    try do
      length(:ets.all())
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_loaded_modules do
    try do
      length(:code.all_loaded())
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_uptime_ms do
    try do
      {wall_clock, _} = :erlang.statistics(:wall_clock)
      wall_clock
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_run_queue do
    try do
      :erlang.statistics(:total_run_queue_lengths)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_gc_count do
    try do
      {gc_count, _, _} = :erlang.statistics(:garbage_collection)
      gc_count
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_gc_words_reclaimed do
    try do
      {_, words_reclaimed, _} = :erlang.statistics(:garbage_collection)
      words_reclaimed
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_logical_processors do
    try do
      :erlang.system_info(:logical_processors)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_process_count do
    try do
      :erlang.system_info(:process_count)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_system_architecture do
    try do
      to_string(:erlang.system_info(:system_architecture))
    rescue
      _ -> "unknown"
    catch
      _, _ -> "unknown"
    end
  end

  # CPU usage tracking using persistent_term for cross-call state
  defp safe_cpu_current do
    try do
      now = :erlang.monotonic_time(:millisecond)
      {total_runtime, _} = :erlang.statistics(:runtime)
      schedulers = safe_schedulers_count()

      case :persistent_term.get(@cpu_sample_key, nil) do
        nil ->
          # First call: initialize with current sample, return nil since we need a delta
          :persistent_term.put(@cpu_sample_key, [{now, total_runtime}])
          nil

        samples when is_list(samples) ->
          {last_time, last_runtime} = List.last(samples)
          wall_delta = max(now - last_time, 1)
          runtime_delta = max(total_runtime - last_runtime, 0)
          cpu_ratio = min(runtime_delta / (wall_delta * schedulers), 1.0)
          current = Float.round(cpu_ratio * 100, 1)

          # Keep samples for up to 1 hour (newest at the end)
          retained =
            (samples ++ [{now, total_runtime}])
            |> Enum.drop_while(fn {t, _} -> now - t > 3_600_000 end)
            |> Enum.take(1000)

          :persistent_term.put(@cpu_sample_key, retained)
          current
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp safe_cpu_hourly_avg do
    try do
      now = :erlang.monotonic_time(:millisecond)
      {total_runtime, _} = :erlang.statistics(:runtime)
      schedulers = safe_schedulers_count()

      case :persistent_term.get(@cpu_sample_key, nil) do
        nil ->
          nil

        samples when is_list(samples) and length(samples) < 2 ->
          nil

        samples when is_list(samples) ->
          {oldest_time, oldest_runtime} = hd(samples)
          wall_delta = max(now - oldest_time, 1)
          runtime_delta = max(total_runtime - oldest_runtime, 0)
          cpu_ratio = min(runtime_delta / (wall_delta * schedulers), 1.0)
          Float.round(cpu_ratio * 100, 1)
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp safe_schedulers_count do
    try do
      :erlang.system_info(:schedulers_online)
    rescue
      _ -> 1
    catch
      _, _ -> 1
    end
  end
end
