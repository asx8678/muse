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
  producing corrupt snapshots on crash. On failure the `.tmp` file is cleaned up.

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

  ## Security

  Values at sensitive key names (tokens, passwords, API keys, etc.) are
  automatically replaced with `"**REDACTED**"` before persistence. Key detection
  follows `Muse.MetadataSanitizer.sensitive_key?/1` semantics (case-insensitive
  substring match against known sensitive patterns).

  Session IDs are validated to block path-traversal characters (`/`, `\\`, NUL)
  and reserved names (`.`, `..`, empty string).
  """

  @default_base_dir ".muse/sessions"
  @schema_version 1
  @redacted "**REDACTED**"

  # Characters that would allow path traversal: forward slash, backslash, NUL
  @path_traversal_chars ~r([/\\\0])

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

  Sensitive keys in the data map are automatically redacted before persistence.
  The write is atomic: content goes to a `.tmp` file first, then is renamed.
  On failure the `.tmp` file is cleaned up.

  Returns:
    - `:ok` on success
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, {:mkdir_failed, reason, dir}}` if the directory cannot be created
    - `{:error, {:encode_failed, reason}}` if the data cannot be serialized
    - `{:error, {:write_failed, reason}}` if the file write fails
  """
  @spec save_session(String.t(), String.t(), map()) :: :ok | {:error, tuple()}
  def save_session(base_dir \\ @default_base_dir, session_id, data) when is_map(data) do
    with :ok <- validate_session_id(session_id),
         {:ok, dir} <- ensure_dir(base_dir, session_id) do
      path = Path.join(dir, "session.json")

      data
      |> scrub_sensitive_keys()
      |> Map.put("schema_version", @schema_version)
      |> Jason.encode()
      |> case do
        {:ok, content} -> atomic_write(path, content)
        {:error, reason} -> {:error, {:encode_failed, reason}}
      end
    end
  end

  @doc """
  Loads a session snapshot from `session.json`.

  Returns:
    - `{:ok, data}` with the decoded map (the `schema_version` field is stripped)
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, :enoent}` if the session does not exist
    - `{:error, {:corrupt_json, reason}}` if the file contains invalid JSON
    - `{:error, reason}` if the file cannot be read
  """
  @spec load_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_session(base_dir \\ @default_base_dir, session_id) do
    with :ok <- validate_session_id(session_id) do
      path = Path.join(session_dir(base_dir, session_id), "session.json")

      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, decoded} -> {:ok, Map.delete(decoded, "schema_version")}
            {:error, reason} -> {:error, {:corrupt_json, reason}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Appends an event to the session's `events.jsonl` file.

  The event can be a plain map or a `%Muse.Event{}` struct. Sensitive keys
  are automatically redacted before persistence. Structs are converted to
  JSON-friendly maps (atom keys → strings, `DateTime` → ISO 8601 string,
  atom values → strings).

  Returns:
    - `:ok` on success
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, {:mkdir_failed, reason, dir}}` if the directory cannot be created
    - `{:error, {:encode_failed, reason}}` if the data cannot be serialized
    - `{:error, {:write_failed, reason}}` if the file write fails
  """
  @spec append_event(String.t(), String.t(), map() | struct()) :: :ok | {:error, tuple()}
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
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, reason}` on file read errors
  """
  @spec load_events(String.t(), String.t()) ::
          {:ok, list(map()), %{skipped: non_neg_integer()}} | {:error, term()}
  def load_events(base_dir \\ @default_base_dir, session_id) do
    load_jsonl(base_dir, session_id, "events.jsonl")
  end

  @doc """
  Appends a message to the session's `messages.jsonl` file.

  Same encoding and redaction rules as `append_event/3`.

  Returns:
    - `:ok` on success
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, {:mkdir_failed, reason, dir}}` if the directory cannot be created
    - `{:error, {:encode_failed, reason}}` if the data cannot be serialized
    - `{:error, {:write_failed, reason}}` if the file write fails
  """
  @spec append_message(String.t(), String.t(), map() | struct()) :: :ok | {:error, tuple()}
  def append_message(base_dir \\ @default_base_dir, session_id, message) do
    append_jsonl(base_dir, session_id, "messages.jsonl", message)
  end

  @doc """
  Loads all messages from the session's `messages.jsonl` file, oldest first.

  Same semantics as `load_events/2`.

  Returns:
    - `{:ok, messages, %{skipped: count}}`
    - `{:ok, [], %{skipped: 0}}` if the file does not exist
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, reason}` on file read errors
  """
  @spec load_messages(String.t(), String.t()) ::
          {:ok, list(map()), %{skipped: non_neg_integer()}} | {:error, term()}
  def load_messages(base_dir \\ @default_base_dir, session_id) do
    load_jsonl(base_dir, session_id, "messages.jsonl")
  end

  # ── Private: Session ID validation ─────────────────────────────────────

  defp validate_session_id(session_id) when is_binary(session_id) do
    cond do
      session_id == "" ->
        {:error, {:invalid_session_id, session_id}}

      session_id in [".", ".."] ->
        {:error, {:invalid_session_id, session_id}}

      Regex.match?(@path_traversal_chars, session_id) ->
        {:error, {:invalid_session_id, session_id}}

      true ->
        :ok
    end
  end

  defp validate_session_id(other) do
    {:error, {:invalid_session_id, other}}
  end

  # ── Private: Sensitive key redaction ──────────────────────────────────

  # Struct modules that Jason can encode natively — do NOT recurse into these.
  @encodable_structs [
    DateTime,
    Date,
    Time,
    NaiveDateTime,
    MapSet,
    Range,
    Version,
    Version.Requirement
  ]

  defp scrub_sensitive_keys(data) when is_struct(data) do
    if data.__struct__ in @encodable_structs do
      # Leave Jason-encodable structs intact
      data
    else
      # Recursively scrub user-defined structs (e.g. Muse.Event)
      data
      |> Map.from_struct()
      |> scrub_map()
    end
  end

  defp scrub_sensitive_keys(data) when is_map(data) do
    scrub_map(data)
  end

  defp scrub_sensitive_keys(data), do: data

  defp scrub_map(map) do
    Map.new(map, fn {key, value} ->
      if Muse.MetadataSanitizer.sensitive_key?(key) do
        {key, @redacted}
      else
        {key, scrub_sensitive_keys(value)}
      end
    end)
  end

  # ── Private: Directory helpers ────────────────────────────────────────

  defp ensure_dir(base_dir, session_id) do
    dir = session_dir(base_dir, session_id)

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, {:mkdir_failed, reason, dir}}
    end
  end

  # ── Private: Atomic write ─────────────────────────────────────────────

  defp atomic_write(path, content) do
    tmp_path = path <> ".tmp"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, {:write_failed, reason}}
    end
  end

  # ── Private: JSONL helpers ─────────────────────────────────────────────

  defp append_jsonl(base_dir, session_id, file_name, data) do
    with :ok <- validate_session_id(session_id),
         {:ok, dir} <- ensure_dir(base_dir, session_id),
         {:ok, line} <- encode_jsonl_line(data) do
      path = Path.join(dir, file_name)

      case File.write(path, line, [:append]) do
        :ok -> :ok
        {:error, reason} -> {:error, {:write_failed, reason}}
      end
    end
  end

  defp load_jsonl(base_dir, session_id, file_name) do
    with :ok <- validate_session_id(session_id) do
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
    |> scrub_sensitive_keys()
    |> encode_for_storage()
    |> Jason.encode()
    |> case do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
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
end
