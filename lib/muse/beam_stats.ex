defmodule Muse.BeamStats do
  @moduledoc """
  Runtime BEAM statistics snapshot.

  Returns a plain map with memory, process, scheduler, and OTP info.
  All values are gathered synchronously; each sub-call is rescued so a
  single failing metric cannot take down the snapshot.
  """

  @spec snapshot() :: map()
  def snapshot do
    %{
      memory: safe_memory(),
      total_memory: safe_total_memory(),
      process_count: safe_process_count(),
      process_limit: safe_process_limit(),
      port_count: safe_port_count(),
      port_limit: safe_port_limit(),
      scheduler_count: safe_scheduler_count(),
      schedulers_online: safe_schedulers_online(),
      otp_release: safe_otp_release(),
      system_version: safe_system_version()
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

  defp safe_process_count do
    try do
      :erlang.system_info(:process_count)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_process_limit do
    try do
      :erlang.system_info(:process_limit)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_port_count do
    try do
      :erlang.system_info(:port_count)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_port_limit do
    try do
      :erlang.system_info(:port_limit)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_scheduler_count do
    try do
      :erlang.system_info(:schedulers)
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp safe_schedulers_online do
    try do
      :erlang.system_info(:schedulers_online)
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
end
