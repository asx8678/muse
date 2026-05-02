defmodule Muse.Application do
  @moduledoc """
  OTP Application callback for Muse.

  Reads boot options, starts the correct supervisor children based on CLI
  flags, and prints the startup banner.

  In the test environment `:start_runtime_children?` defaults to `false`
  so that existing tests (which manually start/stop globally-named
  processes like `Muse.State` and `Muse.Workspace`) are not broken by
  automatic supervisor startups.
  """

  use Application

  alias Muse.{Argv, BootOptions, StartupBanner}

  # -- Application callback -----------------------------------------------------

  @impl true
  def start(_type, _args) do
    if start_runtime_children?() do
      opts = BootOptions.parse!(Argv.get())

      if opts.help? do
        IO.puts(help_text())
        halt_fun().(0)
      end

      maybe_configure_endpoint(opts)
      children = runtime_children(opts)
      StartupBanner.io_puts(banner_opts(opts))
      Supervisor.start_link(children, strategy: :one_for_one, name: Muse.Supervisor)
    else
      Supervisor.start_link(base_children(), strategy: :one_for_one, name: Muse.Supervisor)
    end
  end

  # -- Children ------------------------------------------------------------------

  @doc false
  @spec base_children() :: [Supervisor.child_spec()]
  def base_children do
    [
      {Phoenix.PubSub, name: Muse.PubSub}
    ]
  end

  @doc false
  @spec runtime_children(BootOptions.t()) :: [Supervisor.child_spec()]
  def runtime_children(opts) do
    children = [
      {Task.Supervisor, name: Muse.TaskSupervisor},
      {Phoenix.PubSub, name: Muse.PubSub},
      Muse.Diagnostics,
      Muse.SelfHealingQueue,
      {Muse.Workspace, root: opts.workspace},
      Muse.State
    ]

    children =
      if opts.cli? do
        children ++ [{Muse.CLI.Repl, [halt?: true]}]
      else
        children
      end

    children =
      if opts.web? do
        children ++ [{MuseWeb.Endpoint, server: true}]
      else
        children
      end

    children =
      if opts.watch? and Application.get_env(:muse, :source_mode?, false) do
        children ++ [Muse.DevReloader]
      else
        children
      end

    children
  end

  # -- Banner opts (reflects effective hot-reload state) -------------------------

  @doc false
  @spec banner_opts(BootOptions.t()) :: keyword()
  def banner_opts(opts) do
    [
      workspace: opts.workspace,
      cli?: opts.cli?,
      web?: opts.web?,
      host: opts.host,
      port: opts.port,
      watch?: effective_watch?(opts)
    ]
  end

  @doc false
  @spec effective_watch?(BootOptions.t()) :: boolean()
  def effective_watch?(opts) do
    opts.watch? and Application.get_env(:muse, :source_mode?, false)
  end

  # -- Host parsing --------------------------------------------------------------

  @doc false
  @spec parse_host(String.t()) :: :inet.ip_address()
  def parse_host(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, tuple} -> tuple
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  # -- Help text -----------------------------------------------------------------

  @doc false
  @spec help_text() :: String.t()
  def help_text do
    """
    Usage: muse [options]

    Options:
      --no-web          Disable web interface
      --web-only        Disable CLI, enable web only
      --no-cli          Alias for --web-only
      --port PORT       HTTP port (default: 4000)
      --host HOST       HTTP host (default: 127.0.0.1)
      --workspace PATH  Workspace directory
      --no-watch        Disable hot reload
      --help, -h        Show this help
    """
  end

  # -- Endpoint env configuration -----------------------------------------------

  @doc false
  @spec maybe_configure_endpoint(BootOptions.t()) :: :ok
  def maybe_configure_endpoint(opts) do
    if opts.web? do
      # Phoenix.Endpoint reads its :http config from application env,
      # not from start_link options.  We must set it here so the
      # actual bind address/port matches what the banner advertises.
      current = Application.get_env(:muse, MuseWeb.Endpoint, [])
      http = Keyword.get(current, :http, [])
      http = Keyword.put(http, :ip, parse_host(opts.host))
      http = Keyword.put(http, :port, opts.port)
      Application.put_env(:muse, MuseWeb.Endpoint, Keyword.put(current, :http, http))
    end

    :ok
  end

  # -- Configurable helpers (test-injectable) ------------------------------------

  defp start_runtime_children? do
    Application.get_env(:muse, :start_runtime_children?, true)
  end

  defp halt_fun do
    Application.get_env(:muse, :halt_fun, &System.halt/1)
  end
end
