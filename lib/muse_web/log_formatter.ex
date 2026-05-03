defmodule MuseWeb.LogFormatter do
  @moduledoc """
  Pure helpers for log formatting, filtering, and display.

  Extracted to keep rendering logic testable and reusable
  without requiring a LiveView socket or running processes.
  """

  alias Muse.LogEntry
  alias MuseWeb.ExportJSON

  # -- Filtering ---------------------------------------------------------------

  @doc "Filter logs by severity level and search query."
  @spec filtered_logs([LogEntry.t()], String.t(), String.t()) :: [LogEntry.t()]
  def filtered_logs(logs, filter, search) do
    logs
    |> filter_by_level(filter)
    |> filter_by_search(search)
  end

  @spec filter_by_level([LogEntry.t()], String.t()) :: [LogEntry.t()]
  def filter_by_level(logs, "all"), do: logs
  def filter_by_level(logs, "errors"), do: Enum.filter(logs, &(&1.level in [:error, :critical]))
  def filter_by_level(logs, "warnings"), do: Enum.filter(logs, &(&1.level == :warning))
  def filter_by_level(logs, "info"), do: Enum.filter(logs, &(&1.level == :info))
  def filter_by_level(logs, "debug"), do: Enum.filter(logs, &(&1.level == :debug))
  def filter_by_level(logs, _), do: logs

  @spec filter_by_search([LogEntry.t()], String.t()) :: [LogEntry.t()]
  def filter_by_search(logs, ""), do: logs
  def filter_by_search(logs, nil), do: logs

  def filter_by_search(logs, query) when is_binary(query) do
    q = String.downcase(query)
    Enum.filter(logs, &log_matches_search?(&1, q))
  end

  def filter_by_search(logs, query), do: filter_by_search(logs, to_string(query))

  defp log_matches_search?(entry, query) do
    searchable_parts = [
      safe_to_string(entry.level),
      safe_to_string(entry.source),
      entry.message,
      inspect(entry.metadata)
    ]

    searchable = searchable_parts |> Enum.join(" ") |> String.downcase()
    String.contains?(searchable, query)
  end

  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value), do: inspect(value)

  # -- Valid log level filters -------------------------------------------------

  @valid_log_filters ~w(all errors warnings info debug)

  @spec valid_log_filters() :: [String.t()]
  def valid_log_filters, do: @valid_log_filters

  @spec valid_log_filter?(String.t()) :: boolean()
  def valid_log_filter?(filter), do: filter in @valid_log_filters

  # -- Display helpers ---------------------------------------------------------

  @spec log_level_display(atom()) :: String.t()
  def log_level_display(:debug), do: "Debug"
  def log_level_display(:info), do: "Info"
  def log_level_display(:warning), do: "Warning"
  def log_level_display(:error), do: "Error"
  def log_level_display(:critical), do: "Critical"
  def log_level_display(_), do: "Unknown"

  @spec log_badge_class(atom()) :: String.t()
  def log_badge_class(:debug), do: "log-badge log-badge-debug"
  def log_badge_class(:info), do: "log-badge log-badge-info"
  def log_badge_class(:warning), do: "log-badge log-badge-warning"
  def log_badge_class(:error), do: "log-badge log-badge-error"
  def log_badge_class(:critical), do: "log-badge log-badge-critical"
  def log_badge_class(_), do: "log-badge log-badge-neutral"

  @spec log_row_class(atom()) :: String.t()
  def log_row_class(level) when level in [:error, :critical], do: "log-row log-row-error"
  def log_row_class(:warning), do: "log-row log-row-warning"
  def log_row_class(_), do: "log-row"

  # -- Timestamp formatting ----------------------------------------------------

  @spec log_timestamp(DateTime.t() | nil) :: String.t()
  def log_timestamp(%DateTime{} = timestamp) do
    timestamp
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end

  def log_timestamp(_), do: "—"

  # -- JSON formatting ---------------------------------------------------------

  @spec log_entry_to_map(LogEntry.t()) :: map()
  def log_entry_to_map(%LogEntry{} = entry) do
    %{
      "id" => entry.id,
      "timestamp" => safe_timestamp_iso(entry.timestamp),
      "level" => safe_to_string(entry.level),
      "source" => safe_to_string(entry.source),
      "message" => safe_to_string(entry.message),
      "metadata" => ExportJSON.json_safe(entry.metadata)
    }
  end

  defp safe_timestamp_iso(%DateTime{} = ts), do: DateTime.to_iso8601(ts)
  defp safe_timestamp_iso(nil), do: nil
  defp safe_timestamp_iso(other), do: safe_to_string(other)

  @spec format_log_json(LogEntry.t()) :: String.t()
  def format_log_json(%LogEntry{} = entry) do
    entry
    |> log_entry_to_map()
    |> Jason.encode!(pretty: true)
  rescue
    e ->
      Jason.encode!(
        %{
          "error" => "Failed to encode log entry JSON",
          "detail" => Exception.message(e),
          "log_id" => entry.id
        },
        pretty: true
      )
  end

  @spec format_logs_json([LogEntry.t()]) :: String.t()
  def format_logs_json(logs) do
    payload = %{
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "total_count" => length(logs),
      "logs" => Enum.map(logs, &log_entry_to_map/1)
    }

    Jason.encode!(payload, pretty: true)
  rescue
    e ->
      Jason.encode!(
        %{
          "error" => "Failed to encode logs JSON",
          "detail" => Exception.message(e)
        },
        pretty: true
      )
  end
end
