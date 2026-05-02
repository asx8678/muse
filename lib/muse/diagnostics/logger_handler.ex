defmodule Muse.Diagnostics.LoggerHandler do
  @moduledoc """
  Erlang/OTP Logger handler that forwards warnings/errors to diagnostics.

  The handler deliberately does not call `Logger` internally.  It is used from
  inside the logging subsystem, so all formatting and forwarding is defensive
  and best-effort.
  """

  @behaviour :logger_handler

  @handler_id :muse_diagnostics
  @handler_config %{level: :warning}
  @inspect_limit 50
  @printable_limit 2_000

  @doc """
  Installs the diagnostics logger handler idempotently.
  """
  @spec install() :: :ok | {:error, term()}
  def install do
    case :logger.add_handler(@handler_id, __MODULE__, @handler_config) do
      :ok ->
        :ok

      {:error, {:already_exist, @handler_id}} ->
        set_warning_level()

      {:error, {:already_exists, @handler_id}} ->
        set_warning_level()

      {:error, {:already_exist, _id}} ->
        set_warning_level()

      {:error, {:already_exists, _id}} ->
        set_warning_level()

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Removes the diagnostics logger handler idempotently.
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

  @doc false
  @spec normalize_level(atom()) :: :warning | :error | :critical | :ignore
  def normalize_level(:warn), do: :warning
  def normalize_level(:warning), do: :warning
  def normalize_level(:error), do: :error
  def normalize_level(:critical), do: :critical
  def normalize_level(:alert), do: :critical
  def normalize_level(:emergency), do: :critical
  def normalize_level(_level), do: :ignore

  # -- :logger_handler callbacks -----------------------------------------------

  @impl :logger_handler
  def adding_handler(config), do: {:ok, Map.merge(@handler_config, config)}

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
        metadata = Map.get(event, :meta, %{})
        safe_emit(level, format_message(msg), metadata)
    end
  end

  defp forward_event(_event), do: :ok

  defp safe_emit(level, message, metadata) do
    case Process.whereis(Muse.Diagnostics) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          Muse.Diagnostics.emit(level, message, metadata)
          :ok
        else
          :ok
        end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # -- Formatting ---------------------------------------------------------------

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

  defp set_warning_level do
    case :logger.set_handler_config(@handler_id, :level, :warning) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
      {:error, {:not_found, _id}} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
