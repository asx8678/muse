defmodule MuseWeb.ExportJSON do
  @moduledoc """
  JSON safety and export helpers for console data.

  Recursively converts arbitrary Elixir terms into Jason-encodable
  structures so that export/copy handlers never crash on non-encodable
  data (atoms, tuples, PIDs, refs, structs, DateTimes, etc.).
  """

  # -- JSON value safety -------------------------------------------------------

  def json_safe(term) when is_binary(term), do: term
  def json_safe(term) when is_boolean(term), do: term
  def json_safe(term) when is_number(term), do: term
  def json_safe(nil), do: nil

  def json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def json_safe(%Date{} = d), do: Date.to_iso8601(d)
  def json_safe(%Time{} = t), do: Time.to_iso8601(t)

  def json_safe(atom) when is_atom(atom), do: to_string(atom)

  def json_safe(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&json_safe/1)
  end

  def json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  # Structs: convert to map, add __struct__ name, safe-ify fields
  def json_safe(%{__struct__: struct_name} = struct) do
    base = Map.delete(struct, :__struct__)

    Map.put(
      Enum.map(base, fn {k, v} -> {json_key(k), json_safe(v)} end) |> Map.new(),
      "__struct__",
      to_string(struct_name)
    )
  end

  def json_safe(map) when is_map(map) do
    Enum.map(map, fn {k, v} -> {json_key(k), json_safe(v)} end) |> Map.new()
  end

  # Fallback: inspect for anything else (PIDs, refs, functions, ports, etc.)
  def json_safe(other), do: inspect(other)

  # -- JSON key safety ---------------------------------------------------------
  #
  # JSON object keys MUST be strings. json_key/1 converts any Elixir term
  # into a string suitable for use as a JSON object key.

  def json_key(key) when is_binary(key), do: key
  def json_key(key) when is_atom(key), do: Atom.to_string(key)
  def json_key(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def json_key(%Date{} = d), do: Date.to_iso8601(d)
  def json_key(%Time{} = t), do: Time.to_iso8601(t)
  def json_key(key) when is_number(key), do: to_string(key)
  def json_key(key), do: inspect(key)

  # -- Diagnostics payload ----------------------------------------------------

  @doc """
  Build a diagnostics export payload from a flat map of assigns.

  Accepts a map (typically `socket.assigns`) instead of a raw socket
  so this function is testable without a LiveView process.
  """
  def build_diagnostics_payload(assigns) when is_map(assigns) do
    workspace = Map.get(assigns, :workspace, "unknown")
    reload_status = Map.get(assigns, :reload_status, %{status: :unknown})
    state = Map.get(assigns, :state, %{events: []})
    diagnostics = Map.get(assigns, :diagnostics, [])
    beam_stats = Map.get(assigns, :beam_stats, %{})
    logs = Map.get(assigns, :logs, [])
    agent_runtime = Map.get(assigns, :agent_runtime, nil)

    log_sample =
      logs
      |> Enum.take(20)
      |> Enum.map(&log_entry_to_safe_map/1)
      |> Enum.reject(&is_nil/1)

    %{
      "app" => "Muse",
      "version" => Application.spec(:muse, :vsn) |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "workspace" => workspace,
      "backend_status" => "connected",
      "reload_status" => to_string(reload_status[:status]),
      "events_count" => length(Map.get(state, :events, [])),
      "logs_count" => length(logs),
      "logs_sample" => log_sample,
      "agent_runtime" => json_safe(agent_runtime || %{}),
      "diagnostics_count" => length(diagnostics),
      "diagnostics" =>
        Enum.map(diagnostics, fn d ->
          %{
            "id" => Map.get(d, :id),
            "level" => to_string(Map.get(d, :level, :unknown)),
            "message" => Map.get(d, :message, ""),
            "timestamp" =>
              case Map.get(d, :timestamp) do
                %DateTime{} = ts -> DateTime.to_iso8601(ts)
                nil -> nil
                other -> to_string(other)
              end,
            "metadata" => json_safe(Map.get(d, :metadata, %{}))
          }
        end),
      "beam_stats" => json_safe(beam_stats)
    }
  end

  defp log_entry_to_safe_map(log) when is_map(log) do
    %{
      "id" => Map.get(log, :id),
      "timestamp" =>
        case Map.get(log, :timestamp) do
          %DateTime{} = ts -> DateTime.to_iso8601(ts)
          nil -> nil
          other -> to_string(other)
        end,
      "level" => to_string(Map.get(log, :level, :info)),
      "source" => to_string(Map.get(log, :source, :unknown)),
      "message" => Map.get(log, :message, ""),
      "metadata" => json_safe(Map.get(log, :metadata, %{}))
    }
  end

  defp log_entry_to_safe_map(_), do: nil
end
