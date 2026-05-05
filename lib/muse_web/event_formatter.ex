defmodule MuseWeb.EventFormatter do
  @moduledoc """
  Pure helpers for event formatting, filtering, and display.

  Extracted from HomeLive to keep rendering logic testable and reusable
  without requiring a LiveView socket.
  """

  alias Muse.Event

  # -- Filtering ---------------------------------------------------------------

  @doc "Filter events by severity and search query."
  def filtered_events(events, filter, search) do
    events
    |> filter_by_severity(filter)
    |> filter_by_search(search)
  end

  def filter_by_severity(events, "all"), do: events

  def filter_by_severity(events, "errors"),
    do: Enum.filter(events, &(event_severity(&1) == :error))

  def filter_by_severity(events, "warnings"),
    do: Enum.filter(events, &(event_severity(&1) == :warning))

  def filter_by_severity(events, "info"),
    do: Enum.filter(events, &(event_severity(&1) == :info))

  def filter_by_severity(events, _), do: events

  def filter_by_search(events, ""), do: events

  def filter_by_search(events, nil), do: events

  def filter_by_search(events, query) when is_binary(query) do
    q = String.downcase(query)
    Enum.filter(events, &event_matches_search?(&1, q))
  end

  def filter_by_search(events, query), do: filter_by_search(events, to_string(query))

  def event_matches_search?(event, query) do
    searchable_parts = [
      Atom.to_string(event.source),
      Atom.to_string(event.type),
      event_display(event),
      inspect(Muse.EventDisplay.safe_data(event.data))
    ]

    searchable = searchable_parts |> Enum.join(" ") |> String.downcase()
    String.contains?(searchable, query)
  end

  # -- Severity classification -------------------------------------------------

  def event_severity(%Event{type: type, data: data}) do
    cond do
      errorish?(type) or errorish?(data) -> :error
      type in [:warning] -> :warning
      true -> :info
    end
  end

  def errorish?(term) when is_atom(term) do
    term in [:error, :failed, :failure, :critical, :reload_failed]
  end

  def errorish?(%{type: type}), do: errorish?(type)

  def errorish?(term) when is_binary(term) do
    String.downcase(term) in ["error", "failed", "failure", "critical"]
  end

  def errorish?(_), do: false

  def successish?(term) when is_atom(term) do
    term in [
      :success,
      :reloaded,
      :fixed,
      :info,
      :reload_success,
      :rollback_success,
      :plan_approved,
      :approval_approved,
      :patch_approved
    ]
  end

  def successish?(term) when is_binary(term) do
    down = String.downcase(term)

    down in [
      "success",
      "reloaded",
      "fixed",
      "info",
      "reload_success",
      "rollback_success",
      "plan_approved",
      "approval_approved",
      "patch_approved"
    ]
  end

  def successish?(_), do: false

  # -- Display helpers --------------------------------------------------------

  def event_display(%Event{} = event), do: Muse.EventDisplay.summary(event)

  def event_row_class(%Event{type: type, data: data}) do
    cond do
      errorish?(type) or errorish?(data) -> "event-row event-row-error"
      successish?(type) -> "event-row event-row-success"
      true -> "event-row"
    end
  end

  def event_badge_class(%Event{type: type, data: data}) do
    cond do
      errorish?(type) or errorish?(data) ->
        "event-badge event-badge-danger"

      successish?(type) ->
        "event-badge event-badge-success"

      type in [
        :user_message,
        :assistant_message,
        :queued_issues_attached,
        :plan_created,
        :plan_approved,
        :plan_rejected,
        :approval_requested,
        :approval_approved,
        :approval_rejected,
        :patch_proposed,
        :patch_approval_requested,
        :patch_approved,
        :patch_rejected
      ] ->
        "event-badge event-badge-accent"

      true ->
        "event-badge event-badge-neutral"
    end
  end

  def event_meta(%Event{timestamp: timestamp, data: data}) do
    parts = []

    parts =
      case timestamp do
        %DateTime{} -> [diagnostic_timestamp(timestamp) | parts]
        _ -> parts
      end

    parts =
      if is_map(data) and Map.has_key?(data, :generation) do
        ["gen #{data[:generation]}" | parts]
      else
        parts
      end

    parts =
      if is_map(data) and is_list(data[:files]) do
        n = length(data[:files])
        label = if n == 1, do: "file", else: "files"
        ["#{n} #{label}" | parts]
      else
        parts
      end

    parts
    |> Enum.reverse()
    |> Enum.join(" · ")
  end

  # -- Timestamp formatting ---------------------------------------------------

  def event_timestamp(%DateTime{} = timestamp) do
    timestamp
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end

  def event_timestamp(_), do: "—"

  def diagnostic_timestamp(%DateTime{} = timestamp) do
    time =
      timestamp
      |> DateTime.to_time()
      |> Time.truncate(:second)
      |> Time.to_string()

    time <> " UTC"
  end

  def format_timestamp(%DateTime{} = ts) do
    ts
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end

  # -- JSON formatting --------------------------------------------------------

  def event_to_map(%Event{} = event) do
    base = %{
      id: event.id,
      timestamp: DateTime.to_iso8601(event.timestamp),
      source: event.source,
      type: event.type,
      data: event.data |> Muse.EventDisplay.safe_data() |> MuseWeb.ExportJSON.json_safe()
    }

    # Add metadata fields when present
    base
    |> maybe_put(:session_id, event.session_id)
    |> maybe_put(:turn_id, event.turn_id)
    |> maybe_put(:seq, event.seq)
    |> maybe_put(:parent_id, event.parent_id)
    |> maybe_put(:visibility, event.visibility)
    |> maybe_put(:muse_id, event.muse_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  def format_event_json(%Event{} = event) do
    event_to_map(event)
    |> Jason.encode!(pretty: true)
  rescue
    e ->
      Jason.encode!(
        %{
          "error" => "Failed to encode event JSON",
          "detail" => Exception.message(e),
          "event_id" => event.id
        },
        pretty: true
      )
  end
end
