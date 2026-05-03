defmodule Muse.LogBuffer.LoggerHandler do
  @moduledoc """
  Erlang/OTP Logger handler that forwards log events to Muse.LogBuffer.

  The handler deliberately does not call `Logger` internally.  It is used
  from inside the logging subsystem, so all formatting and forwarding is
  defensive and best-effort.  It never recursively logs.
  """

  @behaviour :logger_handler

  @handler_id :muse_log_buffer
  @default_config %{level: :info}
  @inspect_limit 50
  @printable_limit 2_000

  @doc """
  Installs the log-buffer logger handler idempotently.

  Options:
    - `:level` — minimum Logger level to capture (default: `:info`)
  """
  @spec install(keyword()) :: :ok | {:error, term()}
  def install(opts \\ []) do
    level = Keyword.get(opts, :level, :info)
    config = Map.put(@default_config, :level, level)

    case :logger.add_handler(@handler_id, __MODULE__, config) do
      :ok ->
        :ok

      {:error, {:already_exist, @handler_id}} ->
        set_level(level)

      {:error, {:already_exists, @handler_id}} ->
        set_level(level)

      {:error, {:already_exist, _id}} ->
        set_level(level)

      {:error, {:already_exists, _id}} ->
        set_level(level)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Removes the log-buffer logger handler idempotently.
  """
  @spec remove() :: :ok | {:error, term()}
  def remove do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
      {:error, {:not_found, _id}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # -- :logger_handler callbacks -----------------------------------------------

  @impl :logger_handler
  def adding_handler(config), do: {:ok, Map.merge(@default_config, config)}

  @impl :logger_handler
  def changing_config(_set_or_update, _old_config, new_config), do: {:ok, new_config}

  @impl :logger_handler
  def filter_config(config), do: config

  @impl :logger_handler
  def removing_handler(_config), do: :ok

  @impl :logger_handler
  def log(event, _config) do
    try do
      forward_event(event)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  # -- Forwarding ---------------------------------------------------------------

  defp forward_event(%{level: raw_level, msg: msg} = event) do
    case normalize_level(raw_level) do
      :ignore ->
        :ok

      level ->
        metadata = extract_metadata(event)
        safe_append(level, format_message(msg), metadata)
    end
  end

  defp forward_event(_event), do: :ok

  defp safe_append(level, message, metadata) do
    case Process.whereis(Muse.LogBuffer) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          Muse.LogBuffer.append(level, message, metadata, :logger)
        end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # -- Level normalization -----------------------------------------------------

  @doc false
  @spec normalize_level(atom()) :: :debug | :info | :warning | :error | :critical | :ignore
  def normalize_level(:debug), do: :debug
  def normalize_level(:info), do: :info
  def normalize_level(:notice), do: :info
  def normalize_level(:warn), do: :warning
  def normalize_level(:warning), do: :warning
  def normalize_level(:error), do: :error
  def normalize_level(:critical), do: :critical
  def normalize_level(:alert), do: :critical
  def normalize_level(:emergency), do: :critical
  def normalize_level(_), do: :ignore

  # -- Message formatting ------------------------------------------------------

  @doc false
  @spec format_message(term()) :: String.t()
  def format_message({:string, chardata}), do: chardata_to_string(chardata)
  def format_message({:report, report}), do: format_report(report)
  def format_message({:report, report, _report_cb}), do: format_report(report)

  def format_message({format, args}) when is_list(args) do
    try do
      format
      |> :io_lib.format(args)
      |> IO.iodata_to_binary()
    rescue
      _ -> safe_inspect({format, args})
    catch
      _, _ -> safe_inspect({format, args})
    end
  end

  def format_message(message), do: chardata_to_string(message)

  defp format_report(report), do: safe_inspect(report)

  defp chardata_to_string(chardata) when is_binary(chardata), do: chardata

  defp chardata_to_string(chardata) do
    try do
      IO.chardata_to_string(chardata)
    rescue
      _ -> safe_inspect(chardata)
    catch
      _, _ -> safe_inspect(chardata)
    end
  end

  defp safe_inspect(term) do
    inspect(term, limit: @inspect_limit, printable_limit: @printable_limit)
  rescue
    _ -> "#Inspect.Error<uninspectable logger message>"
  catch
    _, _ -> "#Inspect.Error<uninspectable logger message>"
  end

  # -- Metadata extraction -----------------------------------------------------

  defp extract_metadata(%{meta: meta}) when is_map(meta) do
    safe_meta =
      meta
      |> Map.take([:application, :mfa, :file, :line, :pid, :time])
      |> Enum.into(%{}, fn {k, v} -> {k, json_safe_value(v)} end)

    safe_meta
  end

  defp extract_metadata(_), do: %{}

  defp json_safe_value(v) when is_atom(v), do: to_string(v)
  defp json_safe_value(v) when is_binary(v), do: v
  defp json_safe_value(v) when is_number(v), do: v
  defp json_safe_value(v) when is_boolean(v), do: v
  defp json_safe_value(nil), do: nil
  defp json_safe_value(pid) when is_pid(pid), do: inspect(pid)
  defp json_safe_value(v), do: inspect(v)

  # -- Handler config helpers --------------------------------------------------

  defp set_level(level) do
    case :logger.set_handler_config(@handler_id, :level, level) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
      {:error, {:not_found, _id}} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
