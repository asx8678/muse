defmodule Muse.Commands do
  @moduledoc """
  Slash-command parser for the Muse web console.

  Returns a structured action tuple so that HomeLive can perform side effects
  without this module knowing about sockets or processes.
  """

  @slash_commands [
    {"/help", :help, "Show available commands"},
    {"/events", :events, "Show event summary"},
    {"/agents", :agents, "Show agent status"},
    {"/simulate event", :simulate_event, "Simulate a test event"},
    {"/simulate backend-error", :simulate_backend_error, "Simulate a backend error"},
    {"/clear", :clear_history, "Clear command history"},
    {"/clear events", :clear_events, "Clear all events"},
    {"/reload-status", :reload_status, "Show reload/watcher status"},
    {"/workspace", :workspace, "Show workspace info"},
    {"/stats", :stats, "Return BEAM stats summary"},
    {"/diagnostics", :diagnostics, "Return diagnostics summary"},
    {"/copy diagnostics", :copy_diagnostics, "Copy diagnostics JSON to clipboard"},
    {"/export events", :export_events, "Export events as JSON to clipboard"},
    {"/search events", :search_events, "Search events by query (e.g. /search events myquery)"},
    {"/filter events", :filter_events, "Filter events by severity (e.g. /filter events errors)"},
    {"/open events", :open_events, "Switch to Events tab"},
    {"/open files", :open_files, "Switch to Files tab"},
    {"/open agents", :open_agents, "Switch to Agents tab"},
    {"/open stats", :open_stats, "Switch to Stats tab"},
    {"/open settings", :open_settings, "Switch to Settings tab"},
    {"/open logs", :open_logs, "Switch to Logs tab"},
    {"/logs", :logs, "Show log summary"},
    {"/clear logs", :clear_logs, "Clear all logs"},
    {"/export logs", :export_logs, "Export logs as JSON to clipboard"},
    {"/search logs", :search_logs, "Search logs by query (e.g. /search logs myquery)"},
    {"/filter logs", :filter_logs, "Filter logs by severity (e.g. /filter logs errors)"},
    {"/runtime", :runtime, "Show agent runtime status"},
    {"/connect runtime", :connect_runtime, "Attempt agent runtime connection"},
    {"/disconnect runtime", :disconnect_runtime, "Disconnect agent runtime"}
  ]

  # Sort longest-prefix-first so "/simulate backend-error" matches before "/simulate"
  @sorted_commands Enum.sort_by(@slash_commands, fn {prefix, _, _} -> -String.length(prefix) end)

  @spec parse(String.t()) ::
          {:command, atom()}
          | {:command, atom(), String.t()}
          | {:message, String.t()}
          | :empty
          | {:unknown, String.t()}
  def parse(text) do
    case String.trim(text) do
      "" -> :empty
      "/" <> _ = cmd -> parse_slash(cmd)
      other -> {:message, other}
    end
  end

  defp parse_slash(cmd) do
    case Enum.find(@sorted_commands, fn {prefix, _, _} ->
           cmd == prefix or String.starts_with?(cmd, prefix <> " ")
         end) do
      {prefix, action, _desc} ->
        args = extract_args(cmd, prefix)
        if args != "", do: {:command, action, args}, else: {:command, action}

      nil ->
        {:unknown, cmd}
    end
  end

  defp extract_args(cmd, prefix) do
    if String.starts_with?(cmd, prefix <> " ") do
      cmd
      |> String.slice((String.length(prefix) + 1)..-1//1)
      |> String.trim()
    else
      ""
    end
  end

  @spec help_text() :: String.t()
  def help_text do
    lines =
      for {cmd, _action, desc} <- @slash_commands do
        pad = String.duplicate(" ", max(1, 24 - String.length(cmd)))
        "  #{cmd}#{pad}— #{desc}"
      end

    (["Available commands:", "" | lines] ++ ["", "You can also type any message to send to Muse."])
    |> Enum.join("\n")
  end

  @spec slash_commands() :: [{String.t(), String.t()}]
  def slash_commands do
    for {cmd, _action, desc} <- @slash_commands, do: {cmd, desc}
  end

  @doc """
  Returns the list of slash commands as JSON-encodable maps.
  Used by the client for autocomplete suggestions.
  """
  @spec slash_commands_json() :: [%{command: String.t(), description: String.t()}]
  def slash_commands_json do
    for {cmd, _action, desc} <- @slash_commands do
      %{command: cmd, description: desc}
    end
  end
end
