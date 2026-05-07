alias Muse.Memory

defmodule Muse.SessionStore do
  @moduledoc """
  Crash-safe persistence for Muse sessions using JSON and JSONL files.

  ## Layout

      <base_dir>/
        <session_id>/
          session.json        # Session snapshot (atomic writes)
          events.jsonl        # Append-only event log
          messages.jsonl      # Append-only message log
          memory.json         # Compacted memory artifact (v0.2.0+)
          patches.jsonl       # Append-only patch proposal log

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
  substring match against known sensitive patterns). Secret-like string values
  under otherwise non-sensitive keys (for example approval reasons containing
  `Bearer ...`, `sk-...`, or `api_key=...`) are also redacted before disk writes.

  Session IDs are validated to block path-traversal characters (`/`, `\\`, NUL)
  and reserved names (`.`, `..`, empty string).

  ## Session Retention (v0.2.0+)

  `evict_sessions/3` enforces a retention policy by removing the oldest sessions
  when the total count exceeds a configurable maximum, and/or by removing sessions
  older than a configurable TTL. Eviction is based on session directory mtime.

  ## Export/Import (v0.2.0+)

  `export_session/3` bundles a session snapshot, events, messages, patches,
  and memory into a single portable map suitable for JSON serialization.
  All data is redacted before export — secrets are never included.

  `import_session/3` writes a portable map back to disk, reconstructing
  the session directory. Imported session IDs are validated for path traversal.

  ## Memory Persistence (v0.2.0+)

  `save_memory/3` and `load_memory/2` persist compacted memory artifacts
  alongside the session. Memory survives restarts and is available for
  the next session init.
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

  @doc """
  Appends a patch proposal to the session's `patches.jsonl` file.

  Same encoding and redaction rules as `append_event/3`.

  Returns:
    - `:ok` on success
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, {:mkdir_failed, reason, dir}}` if the directory cannot be created
    - `{:error, {:encode_failed, reason}}` if the data cannot be serialized
    - `{:error, {:write_failed, reason}}` if the file write fails
  """
  @spec append_patch(String.t(), String.t(), map() | struct()) :: :ok | {:error, tuple()}
  def append_patch(base_dir \\ @default_base_dir, session_id, patch) do
    append_jsonl(base_dir, session_id, "patches.jsonl", patch)
  end

  @doc """
  Loads all patch proposals from the session's `patches.jsonl` file, oldest first.

  Same semantics as `load_events/2`.

  Returns:
    - `{:ok, patches, %{skipped: count}}`
    - `{:ok, [], %{skipped: 0}}` if the file does not exist
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, reason}` on file read errors
  """
  @spec load_patches(String.t(), String.t()) ::
          {:ok, list(map()), %{skipped: non_neg_integer()}} | {:error, term()}
  def load_patches(base_dir \\ @default_base_dir, session_id) do
    load_jsonl(base_dir, session_id, "patches.jsonl")
  end

  # ── Listing and deletion ────────────────────────────────────────────────

  @doc """
  Lists all session IDs present in the base directory.

  Only top-level directories that pass `SessionStore.validate_session_id/1` are returned.
  Returns `{:ok, ids}` or `{:error, reason}`.

  ## Examples

      iex> {:ok, ids} = Muse.SessionStore.list_sessions(".muse/sessions")
      iex> is_list(ids)
      true
  """
  @spec list_sessions(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_sessions(base_dir \\ @default_base_dir) do
    case File.ls(base_dir) do
      {:ok, entries} ->
        ids =
          entries
          |> Enum.filter(fn entry ->
            dir = Path.join(base_dir, entry)
            File.dir?(dir) and validate_session_id(entry) == :ok
          end)
          |> Enum.sort()

        {:ok, ids}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks whether a session directory exists and contains a `session.json`.

  Returns `true` if the session exists, `false` otherwise.
  """
  @spec session_exists?(String.t(), String.t()) :: boolean()
  def session_exists?(base_dir \\ @default_base_dir, session_id) do
    with :ok <- validate_session_id(session_id) do
      path = Path.join(session_dir(base_dir, session_id), "session.json")
      File.exists?(path)
    else
      {:error, _} -> false
    end
  end

  @doc """
  Deletes a session directory and all its contents.

  Returns:
    - `:ok` on success
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, {:delete_failed, reason}}` if the directory cannot be removed
  """
  @spec delete_session(String.t(), String.t()) :: :ok | {:error, tuple()}
  def delete_session(base_dir \\ @default_base_dir, session_id) do
    with :ok <- validate_session_id(session_id) do
      dir = session_dir(base_dir, session_id)

      case File.rm_rf(dir) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, {:delete_failed, reason}}
      end
    end
  end

  # ── Retention policy ────────────────────────────────────────────────────

  @doc """
  Enforces a session retention policy by evicting the oldest sessions.

  ## Options

    * `:max_sessions` — maximum number of sessions to retain (default: unlimited)
    * `:ttl_seconds` — maximum age in seconds for a session directory (default: unlimited)

  Sessions are evicted based on directory modification time (oldest first).
  TTL-evicted sessions are removed regardless of the total count.

  Returns `{:ok, evicted_ids}` with the list of session IDs that were removed,
  or `{:error, reason}` on failure.

  ## Examples

      # Keep only the 10 most recent sessions
      {:ok, evicted} = Muse.SessionStore.evict_sessions(".muse/sessions", max_sessions: 10)

      # Remove sessions older than 7 days
      {:ok, evicted} = Muse.SessionStore.evict_sessions(".muse/sessions", ttl_seconds: 604_800)
  """
  @spec evict_sessions(String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def evict_sessions(base_dir \\ @default_base_dir, opts \\ []) do
    max_sessions = Keyword.get(opts, :max_sessions)
    ttl_seconds = Keyword.get(opts, :ttl_seconds)

    with {:ok, ids} <- list_sessions(base_dir) do
      # Build list of {id, mtime} for age-based eviction
      id_mtimes =
        ids
        |> Enum.map(fn id ->
          dir = session_dir(base_dir, id)

          mtime =
            case File.stat(dir) do
              {:ok, %File.Stat{mtime: mtime}} ->
                # mtime is an Erlang datetime {{Y,M,D},{H,M,S}};
                # convert to seconds since epoch for comparison
                :calendar.datetime_to_gregorian_seconds(mtime)

              _ ->
                0
            end

          {id, mtime}
        end)
        |> Enum.sort_by(fn {_id, mtime} -> mtime end)

      # TTL eviction: remove sessions older than ttl_seconds
      # Convert now (seconds since epoch) to gregorian seconds for comparison
      now_gregorian = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())

      ttl_evicted =
        if ttl_seconds do
          id_mtimes
          |> Enum.filter(fn {_id, mtime} ->
            mtime > 0 and now_gregorian - mtime > ttl_seconds
          end)
          |> Enum.map(fn {id, _mtime} -> id end)
        else
          []
        end

      # Count eviction: remove oldest sessions exceeding max_sessions
      remaining_after_ttl =
        id_mtimes
        |> Enum.reject(fn {id, _mtime} -> id in ttl_evicted end)

      count_evicted =
        if max_sessions && length(remaining_after_ttl) > max_sessions do
          excess = length(remaining_after_ttl) - max_sessions

          remaining_after_ttl
          |> Enum.take(excess)
          |> Enum.map(fn {id, _mtime} -> id end)
        else
          []
        end

      evicted = Enum.uniq(ttl_evicted ++ count_evicted)

      # Perform deletions
      for id <- evicted, reduce: [] do
        acc ->
          case delete_session(base_dir, id) do
            :ok -> [id | acc]
            {:error, _} -> acc
          end
      end
      |> Enum.reverse()
      |> then(&{:ok, &1})
    end
  end

  # ── Memory persistence ──────────────────────────────────────────────────

  @doc """
  Saves a memory artifact to `memory.json` inside the session directory.

  By default, the memory map is redacted through the same sensitive-key
  scrubbing pipeline as session data. When `validate: true` is passed,
  the memory is validated through `Muse.Memory.validate_no_secrets/1`
  **before** any disk write. If validation fails, the memory is **not**
  written and `{:error, {:unsafe_memory, reasons}}` is returned — the
  fail-closed approach preferred by callers like `SessionServer.set_memory/2`.

  Writes are atomic.

  Returns:
    - `:ok` on success
    - `{:error, {:unsafe_memory, reasons}}` if `validate: true` and secrets detected
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, reason}` on other failures
  """
  @spec save_memory(String.t(), String.t(), map(), keyword()) ::
          :ok | {:error, tuple()}
  def save_memory(base_dir \\ @default_base_dir, session_id, memory, opts \\ [])
      when is_map(memory) do
    with :ok <- validate_session_id(session_id) do
      # Fail-closed: when validate: true, reject unsafe memory before any I/O.
      if Keyword.get(opts, :validate, false) do
        case Memory.validate_no_secrets(memory) do
          :ok ->
            do_save_memory(base_dir, session_id, memory)

          {:error, reasons} ->
            {:error, {:unsafe_memory, reasons}}
        end
      else
        do_save_memory(base_dir, session_id, memory)
      end
    end
  end

  @doc """
  Loads a memory artifact from `memory.json`.

  By default, the loaded memory is returned as-is. When `validate: true`
  is passed, the memory is validated through `Muse.Memory.validate_no_secrets/1`
  and unsafe memory is rejected with `{:error, {:unsafe_memory, reasons}}`
  rather than returned to the caller.

  Returns:
    - `{:ok, memory}` with the decoded map (the `schema_version` field is stripped)
    - `{:error, {:unsafe_memory, reasons}}` if `validate: true` and secrets detected
    - `{:error, :enoent}` if no memory file exists
    - `{:error, {:corrupt_json, reason}}` if the file contains invalid JSON
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
  """
  @spec load_memory(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def load_memory(base_dir \\ @default_base_dir, session_id, opts \\ []) do
    with :ok <- validate_session_id(session_id) do
      path = Path.join(session_dir(base_dir, session_id), "memory.json")

      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, decoded} ->
              decoded = Map.delete(decoded, "schema_version")

              if Keyword.get(opts, :validate, false) do
                case Memory.validate_no_secrets(decoded) do
                  :ok -> {:ok, decoded}
                  {:error, reasons} -> {:error, {:unsafe_memory, reasons}}
                end
              else
                {:ok, decoded}
              end

            {:error, reason} ->
              {:error, {:corrupt_json, reason}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes a session's persisted `memory.json` artifact.

  The session ID is validated before constructing the file path so callers
  cannot remove files outside the session directory via path traversal.
  Missing memory files are treated as success.
  """
  @spec delete_memory(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_memory(base_dir \\ @default_base_dir, session_id) do
    with :ok <- validate_session_id(session_id) do
      path = Path.join(session_dir(base_dir, session_id), "memory.json")

      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:delete_failed, reason}}
      end
    end
  end

  # ── Export/Import ──────────────────────────────────────────────────────

  @export_schema_version 1

  @doc """
  Exports a session to a portable map suitable for JSON serialization.

  Bundles the session snapshot, events, messages, patches, and memory
  into a single map. All data is redacted through the sensitive-key
  scrubbing pipeline — secrets are never included in the export.

  Returns:
    - `{:ok, export_map}` on success
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, reason}` on other failures
  """
  @spec export_session(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def export_session(base_dir \\ @default_base_dir, session_id) do
    with :ok <- validate_session_id(session_id),
         true <-
           session_exists?(base_dir, session_id) ||
             {:error, :enoent} do
      with {:ok, snapshot} <- load_session(base_dir, session_id),
           {:ok, events, _} <- load_events(base_dir, session_id),
           {:ok, messages, _} <- load_messages(base_dir, session_id),
           {:ok, patches, _} <- load_patches(base_dir, session_id) do
        memory_result = load_memory(base_dir, session_id)

        # Snapshot was already redacted on save, but apply a final
        # scrub pass for defense-in-depth (no-op on already-redacted data).
        export =
          %{
            "export_schema_version" => @export_schema_version,
            "session_id" => session_id,
            "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "snapshot" => scrub_sensitive_keys(snapshot),
            "events" => Enum.map(events, &scrub_sensitive_keys/1),
            "messages" => Enum.map(messages, &scrub_sensitive_keys/1),
            "patches" => Enum.map(patches, &scrub_sensitive_keys/1)
          }
          |> maybe_put_memory(memory_result)

        {:ok, export}
      end
    end
  end

  defp maybe_put_memory(export, {:ok, memory}),
    do: Map.put(export, "memory", scrub_sensitive_keys(memory))

  defp maybe_put_memory(export, _), do: export

  @doc """
  Imports a session from a portable export map.

  Writes the snapshot, events, messages, patches, and memory back to
  the session directory. The `session_id` can be overridden via the
  `:session_id` option to import under a different ID; otherwise the
  `session_id` from the export map is used.

  All session IDs are validated for path traversal. Imported data is
  scrubbed before writing as an additional safety measure.

  Returns:
    - `{:ok, session_id}` on success
    - `{:error, {:invalid_session_id, id}}` if the session ID is invalid
    - `{:error, {:invalid_export, reason}}` if the export map is malformed
    - `{:error, reason}` on other failures
  """
  @spec import_session(String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def import_session(base_dir \\ @default_base_dir, export, opts \\ []) do
    with :ok <- validate_export_map(export) do
      session_id = Keyword.get(opts, :session_id) || Map.get(export, "session_id")

      with :ok <- validate_session_id(session_id),
           {:ok, import_data} <- prepare_import_data(export) do
        %{
          snapshot: snapshot,
          events_jsonl: events_jsonl,
          messages_jsonl: messages_jsonl,
          patches_jsonl: patches_jsonl,
          memory: memory
        } = import_data

        with :ok <- save_session(base_dir, session_id, snapshot),
             :ok <- write_jsonl_content(base_dir, session_id, "events.jsonl", events_jsonl),
             :ok <- write_jsonl_content(base_dir, session_id, "messages.jsonl", messages_jsonl),
             :ok <- write_jsonl_content(base_dir, session_id, "patches.jsonl", patches_jsonl),
             :ok <- write_import_memory(base_dir, session_id, memory) do
          {:ok, session_id}
        end
      end
    end
  end

  defp validate_export_map(export) when is_map(export) do
    cond do
      not Map.has_key?(export, "session_id") ->
        {:error, {:invalid_export, "missing session_id"}}

      not is_binary(Map.get(export, "session_id")) ->
        {:error, {:invalid_export, "session_id must be a string"}}

      not Map.has_key?(export, "snapshot") ->
        {:error, {:invalid_export, "missing snapshot"}}

      true ->
        :ok
    end
  end

  defp validate_export_map(_), do: {:error, {:invalid_export, "export must be a map"}}

  defp prepare_import_data(export) do
    with {:ok, snapshot} <- import_map(export, "snapshot"),
         {:ok, events_jsonl} <- prepare_import_jsonl(export, "events"),
         {:ok, messages_jsonl} <- prepare_import_jsonl(export, "messages"),
         {:ok, patches_jsonl} <- prepare_import_jsonl(export, "patches"),
         {:ok, memory} <- import_optional_map(export, "memory"),
         :ok <- validate_session_snapshot(snapshot),
         :ok <- validate_memory(memory) do
      {:ok,
       %{
         snapshot: snapshot,
         events_jsonl: events_jsonl,
         messages_jsonl: messages_jsonl,
         patches_jsonl: patches_jsonl,
         memory: memory
       }}
    end
  end

  defp import_map(export, field) do
    case Map.fetch(export, field) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_export, "#{field} must be a map"}}
      :error -> {:error, {:invalid_export, "missing #{field}"}}
    end
  end

  defp import_optional_map(export, field) do
    case Map.fetch(export, field) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_export, "#{field} must be a map"}}
      :error -> {:ok, nil}
    end
  end

  defp prepare_import_jsonl(export, field) do
    entries = Map.get(export, field, [])

    cond do
      not is_list(entries) ->
        {:error, {:invalid_export, "#{field} must be a list"}}

      not Enum.all?(entries, &is_map/1) ->
        {:error, {:invalid_export, "#{field} entries must be maps"}}

      true ->
        encode_jsonl_entries(entries)
    end
  end

  defp validate_session_snapshot(snapshot) do
    snapshot
    |> scrub_sensitive_keys()
    |> Map.put("schema_version", @schema_version)
    |> Jason.encode()
    |> case do
      {:ok, _content} -> :ok
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp validate_memory(nil), do: :ok

  defp validate_memory(memory) when is_map(memory) do
    # Fail-closed: validate memory for secrets before accepting import.
    # Also verify it's encodable (defense-in-depth).
    with :ok <-
           Memory.validate_no_secrets(memory) do
      memory
      |> encode_for_storage()
      |> scrub_sensitive_keys()
      |> Map.put("schema_version", @schema_version)
      |> Jason.encode()
      |> case do
        {:ok, _content} -> :ok
        {:error, reason} -> {:error, {:encode_failed, reason}}
      end
    else
      {:error, reasons} -> {:error, {:unsafe_memory, reasons}}
    end
  end

  defp encode_jsonl_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      entry
      |> scrub_sensitive_keys()
      |> encode_for_storage()
      |> Jason.encode()
      |> case do
        {:ok, json} -> {:cont, {:ok, [json | acc]}}
        {:error, reason} -> {:halt, {:error, {:encode_failed, reason}}}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, ""}
      {:ok, encoded} -> {:ok, encoded |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_jsonl_content(base_dir, session_id, file_name, content) when is_binary(content) do
    with :ok <- validate_session_id(session_id),
         {:ok, dir} <- ensure_dir(base_dir, session_id) do
      path = Path.join(dir, file_name)

      case File.write(path, content) do
        :ok -> :ok
        {:error, reason} -> {:error, {:write_failed, reason}}
      end
    end
  end

  defp write_import_memory(base_dir, session_id, nil) do
    remove_session_file(base_dir, session_id, "memory.json")
  end

  defp write_import_memory(base_dir, session_id, memory) when is_map(memory) do
    # Fail-closed: validate imported memory before persisting
    save_memory(base_dir, session_id, memory, validate: true)
  end

  defp remove_session_file(base_dir, session_id, file_name) do
    with :ok <- validate_session_id(session_id) do
      path = Path.join(session_dir(base_dir, session_id), file_name)

      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:write_failed, reason}}
      end
    end
  end

  # ── Private: Memory persistence internals ────────────────────────────

  defp do_save_memory(base_dir, session_id, memory) do
    with {:ok, dir} <- ensure_dir(base_dir, session_id) do
      path = Path.join(dir, "memory.json")

      data =
        memory
        |> encode_for_storage()
        |> scrub_sensitive_keys()
        |> Map.put("schema_version", @schema_version)

      case Jason.encode(data) do
        {:ok, content} -> atomic_write(path, content)
        {:error, reason} -> {:error, {:encode_failed, reason}}
      end
    end
  end

  # ── Session ID validation ──────────────────────────────────────────

  @max_session_id_length 255

  @doc """
  Validates a session ID for safe use in file paths and runtime registration.

  Returns `:ok` if the session ID is valid, or
  `{:error, {:invalid_session_id, id}}` if it is:

    - not a binary
    - empty (`""`)
    - `"."` or `".."`
    - contains path-traversal characters (`/`, `\\`, NUL)
    - exceeds the maximum length of `#{@max_session_id_length}` characters

  This function is the canonical validator used by `SessionStore`,
  `SessionRouter`, and `SessionServer` to reject invalid or dangerous
  session IDs before any Registry lookup, process start, or file I/O.
  """
  @spec validate_session_id(term()) :: :ok | {:error, {:invalid_session_id, term()}}
  def validate_session_id(session_id) when is_binary(session_id) do
    cond do
      session_id == "" ->
        {:error, {:invalid_session_id, session_id}}

      session_id in [".", ".."] ->
        {:error, {:invalid_session_id, session_id}}

      Regex.match?(@path_traversal_chars, session_id) ->
        {:error, {:invalid_session_id, session_id}}

      byte_size(session_id) > @max_session_id_length ->
        {:error, {:invalid_session_id, session_id}}

      true ->
        :ok
    end
  end

  def validate_session_id(other) do
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

  defp scrub_sensitive_keys(data) when is_list(data) do
    Enum.map(data, &scrub_sensitive_keys/1)
  end

  defp scrub_sensitive_keys(data) when is_tuple(data) do
    data
    |> Tuple.to_list()
    |> Enum.map(&scrub_sensitive_keys/1)
    |> List.to_tuple()
  end

  defp scrub_sensitive_keys(data) when is_binary(data) do
    Muse.EventPayloadRedactor.redact_string(data)
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
