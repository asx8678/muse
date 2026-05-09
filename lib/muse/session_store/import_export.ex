defmodule Muse.SessionStore.ImportExport do
  @moduledoc """
  Session import/export logic for `Muse.SessionStore`.

  Handles portable export (redacted snapshot) and import (validation
  + restoration) of session data. Separating this from the core
  persistence API keeps SessionStore focused on read/write operations.

  ## Lifecycle

  - `export_session/2` — called when a user requests `/export session`
  - `import_session/3` — called when a user requests `/import session`

  Both are side-effecting (file I/O) but validate inputs thoroughly
  before writing to prevent data corruption.
  """

  alias Muse.SessionStore

  @doc """
  Export a session as a portable, redacted map.

  Includes events, messages, patches, and optionally memory.
  Sensitive keys are scrubbed before serialization.
  """
  @spec export_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def export_session(base_dir \\ ".muse/sessions", session_id) do
    with {:ok, data} <- SessionStore.load_session(base_dir, session_id) do
      events = load_export_events(base_dir, session_id)
      messages = load_export_messages(base_dir, session_id)
      patches = load_export_patches(base_dir, session_id)
      memory = load_export_memory(base_dir, session_id)

      export =
        %{
          "version" => 1,
          "session_id" => session_id,
          "snapshot" => scrub_sensitive_keys(data),
          "events" => scrub_sensitive_keys(events),
          "messages" => scrub_sensitive_keys(messages),
          "patches" => scrub_sensitive_keys(patches)
        }
        |> maybe_put_memory(memory)

      {:ok, export}
    end
  end

  @doc """
  Import a session from a portable export map.

  Validates the export structure and writes events, messages,
  patches, and optionally memory to the session's JSONL files.
  """
  @spec import_session(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def import_session(base_dir \\ ".muse/sessions", export, opts \\ []) do
    with :ok <- validate_export_map(export) do
      data = prepare_import_data(export)

      session_id = Map.get(export, "session_id") || generate_import_session_id(opts)

      with :ok <- validate_import_jsonl(export, "events"),
           :ok <- validate_import_jsonl(export, "messages"),
           :ok <- validate_import_jsonl(export, "patches") do
        # Write events, messages, patches
        if events = import_map(export, "events") do
          encode_and_write_jsonl_entries(base_dir, session_id, "events.jsonl", events)
        end

        if messages = import_map(export, "messages") do
          encode_and_write_jsonl_entries(base_dir, session_id, "messages.jsonl", messages)
        end

        if patches = import_map(export, "patches") do
          encode_and_write_jsonl_entries(base_dir, session_id, "patches.jsonl", patches)
        end

        # Write snapshot
        if snapshot = import_map(export, "snapshot") do
          :ok = validate_session_snapshot(snapshot)
          SessionStore.save_session(base_dir, session_id, snapshot)
        end

        # Write memory
        memory = import_optional_map(export, "memory")
        write_import_memory(base_dir, session_id, memory)

        {:ok, %{session_id: session_id, imported: Map.keys(data) |> Enum.reject(&is_nil/1)}}
      end
    end
  end

  # -- Private helpers ----------------------------------------------------------

  defp load_export_events(base_dir, session_id) do
    case SessionStore.load_events(base_dir, session_id) do
      {:ok, events} -> events
      _ -> []
    end
  end

  defp load_export_messages(base_dir, session_id) do
    case SessionStore.load_messages(base_dir, session_id) do
      {:ok, messages} -> messages
      _ -> []
    end
  end

  defp load_export_patches(base_dir, session_id) do
    case SessionStore.load_patches(base_dir, session_id) do
      {:ok, patches} -> patches
      _ -> []
    end
  end

  defp load_export_memory(base_dir, session_id) do
    case SessionStore.load_memory(base_dir, session_id) do
      {:ok, memory} -> {:ok, memory}
      _ -> nil
    end
  end

  defp maybe_put_memory(export, {:ok, memory}), do: Map.put(export, "memory", memory)
  defp maybe_put_memory(export, _), do: export

  defp validate_export_map(export) when is_map(export) do
    if Map.has_key?(export, "version") do
      :ok
    else
      {:error, {:invalid_export, "export must contain a 'version' field"}}
    end
  end

  defp validate_export_map(_), do: {:error, {:invalid_export, "export must be a map"}}

  defp prepare_import_data(export) do
    %{
      events: import_map(export, "events"),
      messages: import_map(export, "messages"),
      patches: import_map(export, "patches"),
      snapshot: import_map(export, "snapshot")
    }
  end

  defp import_map(export, field) do
    case Map.get(export, field) do
      nil -> nil
      entries when is_list(entries) -> entries
      _ -> nil
    end
  end

  defp import_optional_map(export, field) do
    case Map.get(export, field) do
      nil -> nil
      entries when is_list(entries) -> entries
      map when is_map(map) -> map
      _ -> nil
    end
  end

  defp validate_import_jsonl(export, field) do
    case Map.get(export, field) do
      nil ->
        :ok

      entries when is_list(entries) ->
        case pre_validate_encodable(entries) do
          :ok -> :ok
          {:error, _} = error -> error
        end

      _ ->
        :ok
    end
  end

  defp pre_validate_encodable(entries) when is_list(entries) do
    if Enum.all?(entries, &encodable?/1) do
      :ok
    else
      {:error, {:invalid_export, "entries in field contain non-encodable values"}}
    end
  end

  defp encodable?(value) when is_map(value), do: true
  defp encodable?(value) when is_list(value), do: true
  defp encodable?(value) when is_binary(value), do: true
  defp encodable?(value) when is_number(value), do: true
  defp encodable?(value) when is_boolean(value), do: true
  defp encodable?(nil), do: true
  defp encodable?(_), do: false

  defp validate_session_snapshot(snapshot) when is_map(snapshot), do: :ok
  defp validate_session_snapshot(_), do: {:error, {:invalid_export, "snapshot must be a map"}}

  defp write_import_memory(_base_dir, _session_id, nil), do: :ok

  defp write_import_memory(base_dir, session_id, memory) when is_map(memory) do
    SessionStore.save_memory(base_dir, session_id, memory)
  end

  defp write_import_memory(_base_dir, _session_id, _memory), do: :ok

  defp encode_and_write_jsonl_entries(base_dir, session_id, file_name, entries) do
    dir = SessionStore.session_dir(base_dir, session_id)
    path = Path.join(dir, file_name)

    lines =
      entries
      |> Enum.map(fn entry ->
        case Jason.encode(entry) do
          {:ok, json} -> json <> "\n"
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    File.mkdir_p!(dir)
    File.write!(path, Enum.join(lines))
  end

  defp generate_import_session_id(opts) do
    Keyword.get(opts, :session_id) ||
      :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Sensitive key scrubbing for safe export
  defp scrub_sensitive_keys(data) when is_struct(data) do
    data |> Map.from_struct() |> scrub_sensitive_keys()
  end

  defp scrub_sensitive_keys(data) when is_map(data) do
    scrub_map(data)
  end

  defp scrub_sensitive_keys(data) when is_list(data) do
    Enum.map(data, &scrub_sensitive_keys/1)
  end

  defp scrub_sensitive_keys(data) when is_tuple(data) do
    data |> Tuple.to_list() |> Enum.map(&scrub_sensitive_keys/1) |> List.to_tuple()
  end

  defp scrub_sensitive_keys(data) when is_binary(data) do
    if String.valid?(data), do: data, else: "<<binary data>>"
  end

  defp scrub_sensitive_keys(data), do: data

  @sensitive_keys MapSet.new([
                    "api_key",
                    "secret",
                    "token",
                    "password",
                    "credential",
                    "authorization",
                    "cookie"
                  ])

  defp scrub_map(map) do
    Map.new(map, fn {key, value} ->
      key_str = to_string(key)

      if MapSet.member?(@sensitive_keys, key_str) do
        {key, "<<redacted>>"}
      else
        {key, scrub_sensitive_keys(value)}
      end
    end)
  end
end
