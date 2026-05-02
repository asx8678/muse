defmodule Muse.Diagnostics do
  @moduledoc """
  Globally-named diagnostics buffer and PubSub broadcaster.

  `Muse.Diagnostics` stores the latest backend warnings/errors and broadcasts
  each new diagnostic to connected LiveViews.  The list is newest-first so the
  UI can render the freshest issue at the top with no additional sorting.
  """

  use GenServer

  alias Muse.Diagnostic
  alias Muse.Diagnostics.LoggerHandler

  @topic "muse:diagnostics"
  @default_max 50

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list() :: [Diagnostic.t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @spec emit(Diagnostic.level() | :warn, term(), term()) :: Diagnostic.t()
  def emit(level, message, metadata \\ %{}) do
    diagnostic = Diagnostic.new(level, message, metadata)
    GenServer.call(__MODULE__, {:emit, diagnostic})
  end

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

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    max = opts |> Keyword.get(:max, @default_max) |> normalize_max()
    install_logger_handler? = Keyword.get(opts, :install_logger_handler?, true)

    if install_logger_handler? do
      _ = LoggerHandler.install()
    end

    {:ok, %{diagnostics: [], max: max, install_logger_handler?: install_logger_handler?}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.diagnostics, state}
  end

  @impl true
  def handle_call({:emit, %Diagnostic{} = diagnostic}, _from, state) do
    diagnostics = [diagnostic | state.diagnostics] |> Enum.take(state.max)
    broadcast({:muse_diagnostic, diagnostic})
    {:reply, diagnostic, %{state | diagnostics: diagnostics}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    broadcast({:muse_diagnostics_cleared})
    {:reply, :ok, %{state | diagnostics: []}}
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
