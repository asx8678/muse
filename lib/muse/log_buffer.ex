defmodule Muse.LogBuffer do
  @moduledoc """
  Globally-named structured log buffer and PubSub broadcaster.

  `Muse.LogBuffer` stores structured log entries and broadcasts each new
  entry to connected LiveViews.  The list is newest-first so the UI can
  render the freshest log at the top with no additional sorting.

  An optional Logger handler (`Muse.LogBuffer.LoggerHandler`) can be
  installed to capture Elixir Logger events.  It is disabled by default
  in tests to avoid global-state side effects.
  """

  use GenServer

  alias Muse.LogEntry

  @topic "muse:logs"
  @default_max 500

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec append(LogEntry.level(), String.t(), map(), LogEntry.source()) :: LogEntry.t()
  def append(level, message, metadata \\ %{}, source \\ :app) do
    entry = LogEntry.new(level, message, metadata, source)
    GenServer.call(__MODULE__, {:append, entry})
  end

  @spec list() :: [LogEntry.t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:error, :pubsub_unavailable}

      _pid ->
        Phoenix.PubSub.subscribe(Muse.PubSub, @topic)
    end
  end

  @spec snapshot() :: %{entries: [LogEntry.t()], count: non_neg_integer()}
  def snapshot do
    entries = list()
    %{entries: entries, count: length(entries)}
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    max = opts |> Keyword.get(:max_entries, @default_max) |> normalize_max()
    install_logger_handler? = Keyword.get(opts, :install_logger_handler?, false)
    logger_level = Keyword.get(opts, :logger_level, :info)

    if install_logger_handler? do
      Muse.LogBuffer.LoggerHandler.install(level: logger_level)
    end

    {:ok,
     %{
       entries: [],
       max: max,
       install_logger_handler?: install_logger_handler?
     }}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.entries, state}
  end

  @impl true
  def handle_call({:append, %LogEntry{} = entry}, _from, state) do
    entries = [entry | state.entries] |> Enum.take(state.max)
    broadcast({:muse_log, entry})
    {:reply, entry, %{state | entries: entries}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    broadcast({:muse_logs_cleared})
    {:reply, :ok, %{state | entries: []}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.install_logger_handler? do
      _ = Muse.LogBuffer.LoggerHandler.remove()
    end

    :ok
  end

  # -- Helpers -----------------------------------------------------------------

  defp normalize_max(max) when is_integer(max) and max > 0, do: max
  defp normalize_max(_max), do: @default_max

  defp broadcast(message) do
    case Process.whereis(Muse.PubSub) do
      nil ->
        :ok

      _pid ->
        Phoenix.PubSub.broadcast(Muse.PubSub, @topic, message)
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
