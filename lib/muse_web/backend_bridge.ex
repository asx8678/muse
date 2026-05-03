defmodule MuseWeb.BackendBridge do
  @moduledoc """
  Compatibility wrapper that delegates to Muse.Backend.

  Existing web callers (HomeLive, ConsoleCommand) continue to import
  this module.  All logic lives in `Muse.Backend` so TUI and REPL
  can share the same safe helpers without pulling in MuseWeb dependencies.
  """

  alias Muse.Backend

  # -- Workspace --------------------------------------------------------------

  defdelegate safe_workspace_root, to: Backend

  # -- Dev reloader -----------------------------------------------------------

  defdelegate safe_reload_status, to: Backend
  defdelegate safe_force_reload, to: Backend

  # -- Diagnostics ------------------------------------------------------------

  defdelegate safe_diagnostics, to: Backend
  defdelegate safe_subscribe_diagnostics, to: Backend
  defdelegate safe_emit_simulated_error, to: Backend

  # -- Self-healing queue -----------------------------------------------------

  defdelegate safe_self_healing_issues, to: Backend
  defdelegate safe_subscribe_self_healing, to: Backend
  defdelegate safe_queue_diagnostic(diagnostic), to: Backend

  # -- Agent registry ---------------------------------------------------------

  defdelegate safe_subscribe_agent_registry, to: Backend
  defdelegate safe_agent_snapshot, to: Backend

  # -- Log buffer -------------------------------------------------------------

  defdelegate safe_logs, to: Backend
  defdelegate safe_log_snapshot, to: Backend
  defdelegate safe_subscribe_logs, to: Backend

  def safe_append_log(level, message, metadata \\ %{}, source \\ :app) do
    Backend.safe_append_log(level, message, metadata, source)
  end

  defdelegate safe_clear_logs, to: Backend

  # -- Agent runtime ----------------------------------------------------------

  defdelegate safe_agent_runtime_snapshot, to: Backend
  defdelegate safe_subscribe_agent_runtime, to: Backend

  def safe_connect_agent_runtime(endpoint \\ nil) do
    Backend.safe_connect_agent_runtime(endpoint)
  end

  defdelegate safe_retry_agent_runtime, to: Backend
  defdelegate safe_disconnect_agent_runtime, to: Backend
  defdelegate safe_set_agent_runtime_endpoint(endpoint), to: Backend
end
