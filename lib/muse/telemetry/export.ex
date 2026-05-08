defmodule Muse.Telemetry.Export do
  @moduledoc """
  Telemetry export handler for external consumption of Muse lifecycle events.

  Supports three export modes:

    * `:stdout` — one JSON object per telemetry event, written to `IO.puts/1`
    * `:file`   — JSONL (one JSON object per line) appended to a configured file
    * `{:mfa, module, function, args}` — pluggable handler for tests/integrations

  ## Safety

  All exported envelopes pass through a defense-in-depth redaction pipeline:

    1. `Muse.MetadataSanitizer.sanitize/1` — sensitive key redaction
    2. `Muse.Prompt.Redactor.redact_term/1` — secret string pattern redaction
       (superset of `EventPayloadRedactor.redact/1` plus DATABASE_URL,
       private key blocks, URL-embedded credentials, etc.)

  Raw secrets (API keys, Bearer tokens, JWTs, passwords, DATABASE_URL
  values, private keys, URL credentials, etc.) must **never** appear in
  exported output.

  ## Attachment

      # From environment (default: off)
      Muse.Telemetry.Export.attach_from_env()

      # Explicit mode
      Muse.Telemetry.Export.attach(:stdout)
      Muse.Telemetry.Export.attach(:file, path: "/var/log/muse/telemetry.jsonl")
      Muse.Telemetry.Export.attach({:mfa, MyHandler, :handle, []})

  ## Detachment

      Muse.Telemetry.Export.detach()

  The handler catches all errors and never crashes the calling process.
  """

  alias Muse.{MetadataSanitizer, Prompt.Redactor, Telemetry}

  @handler_id {__MODULE__, :export_handler}

  # -- Public API ---------------------------------------------------------------

  @doc """
  Attach an export handler for all Muse telemetry events.

  ## Modes

    * `:stdout` — prints one JSON object per event to stdout
    * `:file`   — appends JSONL to the file at `opts[:path]`
    * `{:mfa, mod, fun, args}` — calls `apply(mod, fun, [event_name, measurements, metadata | args])`

  Returns `:ok` on success or `{:error, reason}` on failure.  Never raises.
  """
  @spec attach(:stdout | :file | {:mfa, module(), atom(), [term()]}, keyword()) ::
          :ok | {:error, term()}
  def attach(mode, opts \\ [])

  def attach(:off, _opts), do: :ok

  def attach(:stdout, _opts) do
    do_attach(:stdout)
  end

  def attach(:file, opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" ->
        # Pre-touch the file with restrictive permissions to reduce TOCTOU:
        # create the file (if it doesn't exist) and chmod 0o600 before any
        # events are written. Non-fatal — relative paths and missing dirs
        # are handled gracefully.
        ensure_file_restrictive(path)
        do_attach({:file, path})

      _ ->
        {:error, :missing_file_path}
    end
  end

  def attach({:mfa, mod, fun, extra_args}, _opts)
      when is_atom(mod) and is_atom(fun) and is_list(extra_args) do
    do_attach({:mfa, mod, fun, extra_args})
  end

  def attach(_mode, _opts), do: {:error, :invalid_mode}

  @doc """
  Attach export handler from environment variables.

  Reads `MUSE_TELEMETRY_EXPORT` (`off` | `stdout` | `file`, default `off`)
  and `MUSE_TELEMETRY_FILE` (required when mode is `file`).

  Returns `:ok` if attached or if mode is off/blank/unknown (no attachment).
  Never crashes startup on misconfiguration.
  """
  @spec attach_from_env() :: :ok | {:error, term()}
  def attach_from_env do
    case System.get_env("MUSE_TELEMETRY_EXPORT", "off") |> String.trim() |> String.downcase() do
      "off" -> :ok
      "" -> :ok
      "stdout" -> attach(:stdout)
      "file" -> attach_from_env_file()
      _ -> :ok
    end
  end

  defp attach_from_env_file do
    case System.get_env("MUSE_TELEMETRY_FILE", "") |> String.trim() do
      "" ->
        {:error, :missing_file_path}

      path ->
        ensure_file_restrictive(path)
        attach(:file, path: path)
    end
  end

  @doc """
  Detach the export handler.

  Idempotent — returns `:ok` even if no handler was attached.
  """
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  catch
    :error, _ -> :ok
  end

  @doc """
  Returns the handler ID used for attachment.
  """
  @spec handler_id() :: term()
  def handler_id, do: @handler_id

  # -- Internal: attachment -----------------------------------------------------

  defp do_attach(config) do
    :telemetry.attach_many(
      @handler_id,
      Telemetry.all_event_names(),
      &handle_event/4,
      config
    )

    :ok
  catch
    :error, {:already_exists, @handler_id} ->
      # Idempotent: detach and re-attach
      :telemetry.detach(@handler_id)
      do_attach(config)

    :error, reason ->
      {:error, reason}
  end

  # -- Handler callback ---------------------------------------------------------

  # This function is called by :telemetry for every event. It must never
  # raise, throw, or exit — otherwise :telemetry detaches the handler.
  # We wrap the ENTIRE body (envelope build + dispatch) in a single
  # try/rescue/catch so ALL failure classes are swallowed.
  defp handle_event(event_name, measurements, metadata, config) do
    try do
      safe_envelope = build_envelope(event_name, measurements, metadata)
      dispatch(config, safe_envelope)
    rescue
      _kind -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp dispatch(:stdout, envelope) do
    case Jason.encode(envelope) do
      {:ok, line} -> IO.puts(line)
      {:error, _} -> :ok
    end
  end

  defp dispatch({:file, path}, envelope) do
    case Jason.encode(envelope) do
      {:ok, line} ->
        # Write with restrictive permissions where practical (Unix only).
        # File.open/2 with :append for efficient JSONL writes.
        case File.open(path, [:append, :utf8], fn file ->
               IO.write(file, line)
               IO.write(file, "\n")
             end) do
          :ok ->
            chmod_restrictive(path)
            :ok

          {:error, _} ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp dispatch({:mfa, mod, fun, extra_args}, envelope) do
    apply(mod, fun, [envelope | extra_args])
  end

  # -- Envelope builder ---------------------------------------------------------

  defp build_envelope(event_name, measurements, metadata) do
    # Defense-in-depth: sanitize metadata (key redaction) then redact
    # secret patterns in all string values. Metadata from Telemetry helpers
    # is already sanitized, but this adds a second layer in case raw
    # metadata bypasses the helpers.
    safe_meta =
      metadata
      |> MetadataSanitizer.sanitize()
      |> Redactor.redact_term()

    %{
      "event" => event_name_to_string(event_name),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "measurements" => sanitize_measurements(measurements),
      "metadata" => safe_meta
    }
  end

  defp event_name_to_string(event_name) when is_list(event_name) do
    event_name
    |> Enum.map(&to_string/1)
    |> Enum.join(".")
  end

  # Measurements should be numeric (duration_ms, token counts) but a bug
  # or misuse could inject raw secret strings. Apply the same defense-in-
  # depth redaction as metadata: MetadataSanitizer for structural safety +
  # key redaction, then Redactor.redact_term for all secret patterns
  # (API keys, DATABASE_URL, private keys, URL credentials, etc.).
  defp sanitize_measurements(measurements) when is_map(measurements) do
    measurements
    |> MetadataSanitizer.sanitize()
    |> Redactor.redact_term()
  end

  defp sanitize_measurements(other) do
    other
    |> MetadataSanitizer.sanitize()
    |> Redactor.redact_term()
  end

  # Pre-create the export file with restrictive permissions to reduce TOCTOU.
  # If the file already exists, chmod it. If the parent directory doesn't
  # exist, silently skip — the file will be created on first write and
  # chmod'd then via chmod_restrictive/1. Non-fatal on any failure.
  defp ensure_file_restrictive(path) do
    try do
      if File.exists?(path) do
        chmod_restrictive(path)
      else
        # Touch: open for write then immediately close.
        case File.open(path, [:write, :utf8], fn _file -> :ok end) do
          :ok -> chmod_restrictive(path)
          {:error, _} -> :ok
        end
      end
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  # Set file permissions to owner-read/write only (0o600) where supported.
  # Non-fatal: if chmod fails (e.g. Windows, read-only FS), silently continue.
  defp chmod_restrictive(path) do
    try do
      :file.change_mode(String.to_charlist(path), 0o600)
    catch
      _kind, _reason -> :ok
    end

    :ok
  end
end
