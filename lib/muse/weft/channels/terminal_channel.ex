defmodule Muse.Weft.Channels.TerminalChannel do
  @moduledoc """
  PTY terminal WebSocket channel.

  Implements `Muse.Weft.Behaviour` and the `Phoenix.Channel` contract
  (without `use Phoenix.Channel`) to route shell input/output between
  a browser or external client and a local shell process.

  ## Topic format

      terminal:<ref>

  One shell process (`Port`) is spawned per channel join. The port is
  closed and the child process killed when the channel terminates.

  The channel is opt-in via config:

      config :muse, :weft, enabled_channels: ["terminal"]
  """

  @behaviour Muse.Weft.Behaviour

  alias MuseWeb.ExternalEventFilter

  # -- Phoenix.Channel contract ------------------------------------------------

  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]},
      shutdown: 5000,
      restart: :temporary
    }
  end

  def start_link(triplet) do
    GenServer.start_link(Phoenix.Channel.Server, triplet, hibernate_after: 15_000)
  end

  def __intercepts__, do: []

  def __socket__(:private) do
    %{log_join: :info, log_handle_in: :debug}
  end

  # -- Config ------------------------------------------------------------------

  defp terminal_enabled? do
    Application.get_env(:muse, :weft, [])
    |> Keyword.get(:enabled_channels, [])
    |> Enum.member?("terminal")
  end

  # -- Phoenix.Channel join ----------------------------------------------------

  def join("terminal:" <> _ = topic, payload, socket) do
    case init(topic, payload, socket) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  def join(_topic, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  # -- Muse.Weft.Behaviour init ------------------------------------------------

  @impl Muse.Weft.Behaviour
  def init(topic, payload, socket) do
    if not terminal_enabled?() do
      {:error, "terminal_channel_disabled"}
    else
      case String.split(topic, ":", parts: 2) do
        ["terminal", ref] ->
          if ExternalEventFilter.valid_session_id?(ref) do
            shell = shell_executable(payload)

            opts = [
              :binary,
              :stream,
              :use_stdio,
              {:env, [{~c"TERM", ~c"xterm-256color"}]}
            ]

            port = open_port(shell, opts)

            socket =
              socket
              |> Phoenix.Socket.assign(:terminal_ref, ref)
              |> Phoenix.Socket.assign(:terminal_port, port)

            {:ok, socket}
          else
            {:error, "invalid_ref"}
          end

        _ ->
          {:error, "invalid_topic"}
      end
    end
  end

  # -- Muse.Weft.Behaviour handle_in ------------------------------------------

  @impl Muse.Weft.Behaviour
  def handle_in("input", %{"data" => data}, socket) do
    port = socket.assigns.terminal_port
    send_to_port(port, data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => _cols, "rows" => _rows}, socket) do
    # Reserved for future SIGWINCH implementation.
    {:reply, {:ok, %{ok: true}}, socket}
  end

  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  # -- Phoenix.Channel handle_info ---------------------------------------------

  def handle_info({port, {:data, output}}, %{assigns: %{terminal_port: port}} = socket) do
    Phoenix.Channel.push(socket, "output", %{data: output})
    {:noreply, socket}
  end

  def handle_info({port, {:exit_status, _status}}, %{assigns: %{terminal_port: port}} = socket) do
    {:stop, :normal, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Muse.Weft.Behaviour terminate -------------------------------------------

  @impl Muse.Weft.Behaviour
  def terminate(_reason, socket) do
    case Map.get(socket.assigns, :terminal_port) do
      nil ->
        :ok

      port ->
        close_port(port)
    end
  end

  # -- Private -----------------------------------------------------------------

  defp shell_executable(payload) do
    case Map.get(payload, "shell") do
      shell when is_binary(shell) and shell != "" -> shell
      _ -> System.get_env("SHELL", "/bin/sh")
    end
  end

  defp open_port(path, opts) do
    module = Application.get_env(:muse, :weft_terminal_port_module, Port)
    module.open({:spawn_executable, path}, opts)
  end

  defp send_to_port(port, data) when is_port(port) do
    send(port, {self(), {:command, data}})
  end

  defp send_to_port(pid, data) when is_pid(pid) do
    send(pid, {self(), {:command, data}})
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp close_port(pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  catch
    _, _ -> :ok
  end
end
