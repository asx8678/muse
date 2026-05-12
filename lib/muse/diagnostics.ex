defmodule Muse.Diagnostics do
  @moduledoc """
  Globally-named diagnostics buffer and PubSub broadcaster.

  `Muse.Diagnostics` stores the latest backend warnings/errors and broadcasts
  each new diagnostic to connected LiveViews.  The list is newest-first so the
  UI can render the freshest issue at the top with no additional sorting.

  ## Session-scoped topics

  Call `subscribe/1` with a session ID to listen on a scoped topic
  (`"muse:diagnostics:<session_id>"`).  `subscribe/0` subscribes to the
  `"default"` session topic.  Use `unsubscribe/1` to leave a scoped topic.
  """

  use GenServer

  alias Muse.Diagnostic
  alias Muse.Diagnostics.LoggerHandler

  @topic "muse:diagnostics"

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list() :: [Diagnostic.t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @spec emit(Diagnostic.level() | :warn, term(), term()) :: :ok
  def emit(level, message, metadata \\ %{}) do
    diagnostic = Diagnostic.new(level, message, metadata)
    GenServer.cast(__MODULE__, {:emit, diagnostic})
    :ok
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: subscribe("default")

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(session_id) do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:error, :pubsub_unavailable}

      _pid ->
        Phoenix.PubSub.subscribe(Muse.PubSub, "muse:diagnostics:#{session_id}")
    end
  end

  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(session_id) do
    Phoenix.PubSub.unsubscribe(Muse.PubSub, "muse:diagnostics:#{session_id}")
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    max = opts |> Keyword.get(:max, Muse.Bounds.diagnostics()) |> normalize_max()
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
  def handle_call(:clear, _from, state) do
    broadcast({:muse_diagnostics_cleared})
    {:reply, :ok, %{state | diagnostics: []}}
  end

  @impl true
  def handle_cast({:emit, %Diagnostic{} = diagnostic}, state) do
    diagnostics = [diagnostic | state.diagnostics] |> Enum.take(state.max)
    broadcast({:muse_diagnostic, diagnostic})
    {:noreply, %{state | diagnostics: diagnostics}}
  end

  # -- Helpers -----------------------------------------------------------------

  defp normalize_max(max) when is_integer(max) and max > 0, do: max
  defp normalize_max(_max), do: Muse.Bounds.diagnostics()

  defp broadcast(message) do
    case Process.whereis(Muse.PubSub) do
      nil ->
        :ok

      _pid ->
        # Global topic for backward compat
        Phoenix.PubSub.broadcast(Muse.PubSub, @topic, message)
        # Default session-scoped topic so subscribe/0 callers receive messages
        Phoenix.PubSub.broadcast(Muse.PubSub, "muse:diagnostics:default", message)
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
