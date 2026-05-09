defmodule MuseWeb.ConsoleComponents.Helpers do
  @moduledoc """
  Formatting and display helpers for `MuseWeb.ConsoleComponents`.

  Centralizes pure formatting functions (bytes, memory keys, agent
  sorting, event-to-message conversion, CSS class helpers) so
  that the main ConsoleComponents module stays focused on HEEx
  template rendering.

  ## Lifecycle

  Called from ConsoleComponents function components during render.
  All functions are pure — no side effects, no socket/process access.
  """

  @doc "Sort agents with roots first, then their children."
  @spec sorted_agents([map()]) :: [map()]
  def sorted_agents(agents) do
    by_id = Map.new(agents, &{&1.id, &1})
    roots = Enum.filter(agents, &(is_nil(&1.parent_id) or not Map.has_key?(by_id, &1.parent_id)))

    Enum.flat_map(roots, fn root ->
      children = Enum.filter(agents, &(&1.parent_id == root.id))
      [root | children]
    end)
  end

  @doc "Format a byte count as a human-readable string."
  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_bytes(_), do: "—"

  @doc "Format a memory key atom as a display string."
  @spec format_mem_key(atom()) :: String.t()
  def format_mem_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def format_mem_key(key), do: to_string(key)

  @doc "Convert a list of events to a simplified message list for chat display."
  @spec events_to_messages([map()]) :: [map()]
  def events_to_messages(events) when is_list(events) do
    events
    |> Enum.filter(&user_visible_event?/1)
    |> Enum.map(fn event ->
      %{
        role: event_source_to_role(event.source),
        content: format_event_data(event.data),
        id: event.id,
        timestamp: event.timestamp
      }
    end)
  end

  # -- Private helpers ----------------------------------------------------------

  defp user_visible_event?(%{visibility: :user}), do: true
  defp user_visible_event?(%{visibility: vis}) when vis in [:user, nil], do: true
  defp user_visible_event?(_), do: false

  defp event_source_to_role(:user), do: :user
  defp event_source_to_role(_), do: :assistant

  defp format_event_data(%{text: text}), do: text
  defp format_event_data(%{file: file}), do: file
  defp format_event_data(%{files: files}) when is_list(files), do: Enum.join(files, ", ")
  defp format_event_data(%{issues: issues}) when is_list(issues), do: "#{length(issues)} issues"
  defp format_event_data(data), do: inspect(data)
end
