defmodule Muse.SessionStore do
  @moduledoc """
  Crash-safe persistence for Muse sessions using JSON and JSONL files.

  ## Layout

      <base_dir>/
        <session_id>/
          session.json        # Session snapshot (atomic writes)
          events.jsonl        # Append-only event log
          messages.jsonl      # Append-only message log

  ## Atomicity

  Session snapshots (`session.json`) are written atomically: content is written
  to a `.tmp` sibling file first, then renamed — preventing partial writes from
  producing corrupt snapshots on crash.

  JSONL files are append-only. Each line is a complete JSON object, so only the
  last (possibly incomplete) line is at risk on crash. The `load_*` functions
  skip corrupt lines and report the count.

  ## Schema versioning

  `session.json` includes a `schema_version` integer field. On load it is
  stripped before returning so callers do not need to handle it. Future
  migration logic can inspect the version field before stripping.

  ## Encoding

  Structs (including `%Muse.Event{}`) are automatically converted to JSON-friendly
  maps: atom keys → strings, `DateTime` → ISO 8601, atom values → strings.
  On decode, plain maps are returned; callers may reconstruct structs from the
  decoded data as needed.
  """

  @default_base_dir ".muse/sessions"
  @schema_version 1

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Returns the directory path for a session.

  ## Examples

      iex> Muse.SessionStore.session_dir(".muse/sessions", "abc123")
      ".muse/sessions/abc123"

      iex> Muse.SessionStore.session_dir("abc123")
      ".muse/sessions/abc123"

  """
  @spec session_dir(String.t(), String.t()) :: String.t()
  def session_dir(base_dir \\ @default_base_dir, session_id) when is_binary(session_id) do
    Path.join([base_dir, session_id])
  end

  @doc """
  Saves a session snapshot atomically to `session.json` inside the session directory.

  The data is serialized to JSON with a `schema_version` field added automatically.
  The write is atomic: content goes to a `.tmp` file first, then is renamed.

  Returns:
    - `:ok` on success
    - `{:error, reason}` if the write fails (e.g., permission denied)
  """
  @spec save_session(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def save_session(base_dir \\ @default_base_dir, session_id, data) when is_map(data) do
    dir = session_dir(base_dir, session_id)
    File.mkdir_p!(dir)

    path = Path.join(dir, "session.json")
    payload = Map.put(data, "schema_version", @schema_version)
    content = Jason.encode!(payload)
    atomic_write(path, content)
  end

  @doc """
  Loads a session snapshot from `session.json`.

  Returns:
    - `{:ok, data}` with the decoded map (the `schema_version` field is stripped)
    - `{:error, reason}` if the file cannot be read or contains invalid JSON
  """
  @spec load_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_session(base_dir \\ @default_base_dir, session_id) do
    path = Path.join(session_dir(base_dir, session_id), "session.json")

    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, Map.delete(decoded, "schema_version")}
    end
  end

  @doc """
  Appends an event to the session's `events.jsonl` file.

  The event can be a plain map or a `%Muse.Event{}` struct. Structs are
  automatically converted to JSON-friendly maps (atom keys → strings,
  `DateTime` → ISO 8601 string, atom values → strings).

  Returns:
    - `:ok` on success
    - `{:error, reason}` if the write fails
  """
  @spec append_event(String.t(), String.t(), map() | struct()) :: :ok | {:error, term()}
  def append_event(base_dir \\ @default_base_dir, session_id, event) do
    append_jsonl(base_dir, session_id, "events.jsonl", event)
  end

  @doc """
  Loads all events from the session's `events.jsonl` file, oldest first.

  Corrupt lines (invalid JSON) are silently skipped; the returned map includes
  a `skipped` count.

  Returns:
    - `{:ok, events, %{skipped: count}}` — `events` is a list of decoded maps
    - `{:ok, [], %{skipped: 0}}` if the file does not exist
    - `{:error, reason}` on file read errors
  """
  @spec load_events(String.t(), String.t()) ::
          {:ok, list(map()), %{skipped: non_neg_integer()}} | {:error, term()}
  def load_events(base_dir \\ @default_base_dir, session_id) do
    load_jsonl(base_dir, session_id, "events.jsonl")
  end

  @doc """
  Appends a message to the session's `messages.jsonl` file.

  Same encoding rules as `append_event/3`.

  Returns:
    - `:ok` on success
    - `{:error, reason}` if the write fails
  """
  @spec append_message(String.t(), String.t(), map() | struct()) :: :ok | {:error, term()}
  def append_message(base_dir \\ @default_base_dir, session_id, message) do
    append_jsonl(base_dir, session_id, "messages.jsonl", message)
  end

  @doc """
  Loads all messages from the session's `messages.jsonl` file, oldest first.

  Same semantics as `load_events/2`.

  Returns:
    - `{:ok, messages, %{skipped: count}}`
    - `{:ok, [], %{skipped: 0}}` if the file does not exist
    - `{:error, reason}` on file read errors
  """
  @spec load_messages(String.t(), String.t()) ::
          {:ok, list(map()), %{skipped: non_neg_integer()}} | {:error, term()}
  def load_messages(base_dir \\ @default_base_dir, session_id) do
    load_jsonl(base_dir, session_id, "messages.jsonl")
  end

  # ── Private: JSONL helpers ─────────────────────────────────────────────

  defp append_jsonl(base_dir, session_id, file_name, data) do
    dir = session_dir(base_dir, session_id)
    File.mkdir_p!(dir)
    path = Path.join(dir, file_name)
    line = encode_jsonl_line(data)
    File.write!(path, line, [:append])
  end

  defp load_jsonl(base_dir, session_id, file_name) do
    path = Path.join(session_dir(base_dir, session_id), file_name)

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        {entries, skipped} = parse_jsonl_lines(lines)
        {:ok, entries, %{skipped: skipped}}

      {:error, :enoent} ->
        {:ok, [], %{skipped: 0}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_jsonl_lines(lines) do
    {parsed, skipped} =
      Enum.reduce(lines, {[], 0}, fn line, {acc, skipped} ->
        line = String.trim(line)

        if line == "" do
          {acc, skipped}
        else
          case Jason.decode(line) do
            {:ok, decoded} -> {[decoded | acc], skipped}
            {:error, _corrupt} -> {acc, skipped + 1}
          end
        end
      end)

    {Enum.reverse(parsed), skipped}
  end

  defp encode_jsonl_line(data) do
    data
    |> encode_for_storage()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp encode_for_storage(data) when is_struct(data) do
    data
    |> Map.from_struct()
    |> encode_map()
  end

  defp encode_for_storage(data) when is_map(data) do
    encode_map(data)
  end

  defp encode_map(map) do
    Map.new(map, fn {key, value} ->
      {encode_key(key), encode_value(value)}
    end)
  end

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key) when is_binary(key), do: key

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value), do: value

  # ── Private: Atomic write ─────────────────────────────────────────────

  defp atomic_write(path, content) do
    tmp_path = path <> ".tmp"
    File.write!(tmp_path, content)
    File.rename!(tmp_path, path)
  end
end
