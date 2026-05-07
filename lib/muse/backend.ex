defmodule Muse.Backend do
  @moduledoc """
  Safe backend process helpers for all Muse interfaces (Web, TUI, REPL).

  Every function safely handles cases where backend processes
  (Workspace, DevReloader, Diagnostics, SelfHealingQueue,
  AgentRegistry, LogBuffer, AgentRuntime) are not running —
  returning fallback values instead of crashing.

  This module contains no web-specific or LiveView-specific code.
  """

  # -- Workspace --------------------------------------------------------------

  def safe_workspace_root do
    case Process.whereis(Muse.Workspace) do
      nil ->
        "unknown"

      pid ->
        if Process.alive?(pid), do: Muse.Workspace.root(), else: "unknown"
    end
  end

  # -- Active workspace -------------------------------------------------------

  def safe_active_workspace do
    case Process.whereis(Muse.ActiveWorkspace) do
      nil ->
        %{profile_name: nil, root_path: "unknown", store_base_dir: ".muse/sessions"}

      pid ->
        if Process.alive?(pid),
          do: Muse.ActiveWorkspace.get(),
          else: %{profile_name: nil, root_path: "unknown", store_base_dir: ".muse/sessions"}
    end
  rescue
    _ -> %{profile_name: nil, root_path: "unknown", store_base_dir: ".muse/sessions"}
  end

  def safe_active_store_base_dir do
    Muse.SessionServer.current_store_base_dir()
  rescue
    _ -> ".muse/sessions"
  catch
    :exit, _ -> ".muse/sessions"
  end

  # -- Dev reloader -----------------------------------------------------------

  def safe_reload_status do
    case Process.whereis(Muse.DevReloader) do
      nil ->
        %{status: :unavailable}

      pid ->
        if Process.alive?(pid) do
          Muse.DevReloader.status()
        else
          %{status: :unavailable}
        end
    end
  end

  def safe_force_reload do
    case Process.whereis(Muse.DevReloader) do
      nil ->
        {:error, :not_running}

      pid ->
        if Process.alive?(pid) do
          try do
            Muse.DevReloader.reload()
            :ok
          rescue
            e -> {:error, Exception.message(e)}
          catch
            :exit, reason -> {:error, "exit: #{inspect(reason)}"}
          end
        else
          {:error, :not_alive}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :process_exit}
  end

  # -- Diagnostics ------------------------------------------------------------

  def safe_diagnostics do
    case Process.whereis(Muse.Diagnostics) do
      nil ->
        []

      pid ->
        if Process.alive?(pid) do
          Muse.Diagnostics.list()
        else
          []
        end
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  def safe_subscribe_diagnostics do
    _ = Muse.Diagnostics.subscribe()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def safe_emit_simulated_error do
    case Process.whereis(Muse.Diagnostics) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          Muse.Diagnostics.emit(
            :error,
            "Simulated backend error for popup testing",
            %{source: :web, simulated?: true}
          )
        end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # -- Self-healing queue -----------------------------------------------------

  def safe_self_healing_issues do
    case Process.whereis(Muse.SelfHealingQueue) do
      nil ->
        []

      pid ->
        if Process.alive?(pid) do
          Muse.SelfHealingQueue.list()
        else
          []
        end
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  def safe_subscribe_self_healing do
    _ = Muse.SelfHealingQueue.subscribe()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def safe_queue_diagnostic(diagnostic) do
    case Process.whereis(Muse.SelfHealingQueue) do
      nil ->
        {:error, :queue_unavailable}

      pid ->
        if Process.alive?(pid) do
          case Muse.SelfHealingQueue.add_diagnostic(diagnostic) do
            %Muse.SelfHealingIssue{} = issue -> {:ok, issue}
            {:error, :duplicate} -> {:error, :duplicate}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :queue_unavailable}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :queue_unavailable}
  end

  # -- Agent registry ---------------------------------------------------------

  def safe_subscribe_agent_registry do
    _ = Muse.AgentRegistry.subscribe()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def safe_agent_snapshot do
    case Process.whereis(Muse.AgentRegistry) do
      nil ->
        :unavailable

      pid ->
        if Process.alive?(pid) do
          Muse.AgentRegistry.snapshot()
        else
          :unavailable
        end
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  # -- Log buffer -------------------------------------------------------------

  def safe_logs do
    case Process.whereis(Muse.LogBuffer) do
      nil ->
        []

      pid ->
        if Process.alive?(pid), do: Muse.LogBuffer.list(), else: []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  def safe_log_snapshot do
    case Process.whereis(Muse.LogBuffer) do
      nil ->
        %{entries: [], count: 0}

      pid ->
        if Process.alive?(pid), do: Muse.LogBuffer.snapshot(), else: %{entries: [], count: 0}
    end
  rescue
    _ -> %{entries: [], count: 0}
  catch
    :exit, _ -> %{entries: [], count: 0}
  end

  def safe_subscribe_logs do
    _ = Muse.LogBuffer.subscribe()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def safe_append_log(level, message, metadata \\ %{}, source \\ :app) do
    case Process.whereis(Muse.LogBuffer) do
      nil ->
        {:error, :log_buffer_unavailable}

      pid ->
        if Process.alive?(pid) do
          entry = Muse.LogBuffer.append(level, message, metadata, source)
          {:ok, entry}
        else
          {:error, :log_buffer_unavailable}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :log_buffer_unavailable}
  end

  def safe_clear_logs do
    case Process.whereis(Muse.LogBuffer) do
      nil ->
        {:error, :log_buffer_unavailable}

      pid ->
        if Process.alive?(pid) do
          Muse.LogBuffer.clear()
          :ok
        else
          {:error, :log_buffer_unavailable}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :log_buffer_unavailable}
  end

  # -- Agent runtime ----------------------------------------------------------

  def safe_agent_runtime_snapshot do
    case Process.whereis(Muse.AgentRuntime) do
      nil ->
        %{
          status: :disconnected,
          endpoint: "",
          last_attempt_at: nil,
          last_error: nil,
          health: :inactive
        }

      pid ->
        if Process.alive?(pid),
          do: Muse.AgentRuntime.snapshot(),
          else: %{
            status: :disconnected,
            endpoint: "",
            last_attempt_at: nil,
            last_error: nil,
            health: :inactive
          }
    end
  rescue
    _ ->
      %{
        status: :disconnected,
        endpoint: "",
        last_attempt_at: nil,
        last_error: nil,
        health: :inactive
      }
  catch
    :exit, _ ->
      %{
        status: :disconnected,
        endpoint: "",
        last_attempt_at: nil,
        last_error: nil,
        health: :inactive
      }
  end

  def safe_subscribe_agent_runtime do
    _ = Muse.AgentRuntime.subscribe()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def safe_connect_agent_runtime(endpoint \\ nil) do
    case Process.whereis(Muse.AgentRuntime) do
      nil ->
        {:error, :agent_runtime_unavailable}

      pid ->
        if Process.alive?(pid) do
          Muse.AgentRuntime.connect(endpoint)
        else
          {:error, :agent_runtime_unavailable}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :agent_runtime_unavailable}
  end

  def safe_retry_agent_runtime do
    case Process.whereis(Muse.AgentRuntime) do
      nil ->
        {:error, :agent_runtime_unavailable}

      pid ->
        if Process.alive?(pid) do
          Muse.AgentRuntime.retry()
        else
          {:error, :agent_runtime_unavailable}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :agent_runtime_unavailable}
  end

  def safe_disconnect_agent_runtime do
    case Process.whereis(Muse.AgentRuntime) do
      nil ->
        {:error, :agent_runtime_unavailable}

      pid ->
        if Process.alive?(pid) do
          Muse.AgentRuntime.disconnect()
        else
          {:error, :agent_runtime_unavailable}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :agent_runtime_unavailable}
  end

  def safe_set_agent_runtime_endpoint(endpoint) do
    case Process.whereis(Muse.AgentRuntime) do
      nil ->
        {:error, :agent_runtime_unavailable}

      pid ->
        if Process.alive?(pid) do
          Muse.AgentRuntime.set_endpoint(endpoint)
        else
          {:error, :agent_runtime_unavailable}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> {:error, :agent_runtime_unavailable}
  end
end
