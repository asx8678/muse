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

  alias Muse.{Argv, BootOptions, Logging, StartupBanner}
  alias Muse.CLI.NifAvailability

  # -- Application callback -----------------------------------------------------

  @impl true
  def start(_type, _args) do
    if start_runtime_children?() do
      :ok = Muse.LLM.ProfileLoader.ensure_initialized()

      case Muse.LLM.ProfileLoader.apply_profile() do
        :ok -> :ok
        {:error, reason} -> IO.warn("Muse profile load failed: #{inspect(reason)}")
      end

      opts = BootOptions.parse!(Argv.get())

      if opts.help? do
        IO.puts(help_text())
        halt_fun().(0)
      end

      if opts.version? do
        IO.puts("muse #{version_string()}")
        halt_fun().(0)
      end

      Logging.configure(if opts.verbose?, do: :verbose, else: opts.cli_ui)
      maybe_configure_endpoint(opts)

      # Validate browser access safety against the EFFECTIVE bind IP
      # (after --host override is applied).  This catches unsafe combos
      # like --host 0.0.0.0 that bypass config/runtime.exs validation.
      if opts.web? do
        MuseWeb.BrowserAccessConfig.assert_safe_for_ip!(Muse.Application.parse_host(opts.host))
      end

      children = runtime_children(opts)
      StartupBanner.io_puts(banner_opts(opts))

      case Supervisor.start_link(children, strategy: :one_for_one, name: Muse.Supervisor) do
        {:ok, _pid} = result ->
          validate_provider_config()
          attach_telemetry_export()
          result

        other ->
          other
      end
    else
      Supervisor.start_link(base_children(), strategy: :one_for_one, name: Muse.Supervisor)
    end
  end

  # -- Children ------------------------------------------------------------------

  @doc false
  @spec base_children() :: [Supervisor.child_spec()]
  def base_children do
    [
      {Task.Supervisor, name: Muse.TaskSupervisor},
      {Phoenix.PubSub, name: Muse.PubSub},
      Muse.SessionRegistry,
      Muse.SessionSupervisor,
      Muse.Execution.TargetRegistry,
      Muse.ActiveWorkspace
    ]
  end

  @doc false
  @spec runtime_children(BootOptions.t()) :: [Supervisor.child_spec()]
  def runtime_children(opts) do
    logger_level =
      Application.get_env(:muse, :logger, []) |> Keyword.get(:buffer_level, :info)

    children = [
      {Task.Supervisor, name: Muse.TaskSupervisor},
      {Phoenix.PubSub, name: Muse.PubSub},
      Muse.SessionRegistry,
      Muse.SessionSupervisor,
      Muse.Execution.TargetRegistry,
      Muse.Diagnostics,
      Muse.SelfHealingQueue,
      {Muse.LogBuffer, [install_logger_handler?: true, logger_level: logger_level]},
      Muse.AgentRuntime,
      {Muse.Workspace, root: opts.workspace},
      Muse.ActiveWorkspace,
      Muse.State,
      Muse.AgentRegistry
    ]

    children =
      case opts.cli_ui do
        :repl ->
          children ++ [{Muse.CLI.Repl, [halt?: true]}]

        :tui ->
          # Guard: ExRatatui NIF must be loadable for TUI mode.
          # Escripts cannot load native NIFs from the archive path,
          # so we fail early with an actionable error message.
          NifAvailability.check!()

          web_url =
            if opts.web? do
              "http://#{opts.host}:#{opts.port}"
            else
              nil
            end

          children ++
            [{Muse.CLI.Tui, [halt?: true, workspace: opts.workspace, web_url: web_url]}]

        :none ->
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
    logs_level =
      if opts.verbose? do
        :debug
      else
        Application.get_env(:muse, :logger, []) |> Keyword.get(:console_level, :warning)
      end

    [
      workspace: opts.workspace,
      web?: opts.web?,
      host: opts.host,
      port: opts.port,
      watch?: effective_watch?(opts),
      ui: opts.cli_ui,
      logs: logs_level
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

  # -- Provider config validation ---------------------------------------------

  # -- Telemetry export --------------------------------------------------------

  defp attach_telemetry_export do
    case Muse.Telemetry.Export.attach_from_env() do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Validate the current provider configuration and emit diagnostics for
  common misconfigurations.

  Emits `:warning` diagnostics for recoverable issues (missing API key,
  invalid base URL) and `:error` diagnostics for critical issues (unknown
  provider, missing model).  Does not raise — the application still starts
  with fake provider as fallback.

  This function is called during application startup and can also be
  invoked manually for troubleshooting.
  """
  @spec validate_provider_config() :: :ok
  def validate_provider_config do
    case Muse.Config.llm_provider_config(System.get_env()) do
      {:ok, config} ->
        provider = Muse.LLM.ProviderConfig.provider_atom(config)

        if provider == :fake do
          # Fake provider is fine — no diagnostics needed
          :ok
        else
          validate_non_fake_config(config)
        end

      {:error, reason} ->
        # Config resolution failed entirely
        maybe_emit_diagnostic(:error, "Provider config invalid: #{safe_provider_message(reason)}")

        maybe_emit_diagnostic(
          :warning,
          "Falling back to fake provider. Set MUSE_PROVIDER and MUSE_MODEL to configure a provider."
        )

        :ok
    end
  end

  defp validate_non_fake_config(config) do
    # Check for common misconfigurations
    if config.model in [nil, ""] do
      maybe_emit_diagnostic(:error, "Model is required for non-fake providers. Set MUSE_MODEL.")
    end

    if config.auth == :api_key and config.env_key do
      # Check if the API key env var is set (don't read its value)
      has_key? = System.get_env(config.env_key) != nil

      unless has_key? do
        maybe_emit_diagnostic(
          :warning,
          "API key env var #{config.env_key} is not set. " <>
            "Authentication will fail. Use /auth status to check credentials."
        )
      end
    end

    if config.base_url in [nil, ""] do
      maybe_emit_diagnostic(
        :error,
        "Base URL is required for network providers. Set the appropriate MUSE_*_BASE_URL."
      )
    end

    :ok
  end

  defp maybe_emit_diagnostic(level, message) do
    # Only emit if Diagnostics GenServer is running (not in test base_children mode).
    # Validation must never make startup fail, even if Diagnostics exits between
    # the availability check and the GenServer.call/3.
    if Process.whereis(Muse.Diagnostics) do
      Muse.Diagnostics.emit(level, "Provider config: #{safe_provider_message(message)}", %{})
    end

    :ok
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :maybe_emit_diagnostic, e)
      :ok
  catch
    :exit, reason ->
      Muse.Diagnostics.SilentRescue.log_rescued_catch(
        __MODULE__,
        :maybe_emit_diagnostic,
        :exit,
        reason
      )

      :ok
  end

  defp safe_provider_message(message) do
    message
    |> safe_provider_to_string()
    |> Muse.Prompt.Redactor.redact_text()
  end

  defp safe_provider_to_string(message) when is_binary(message), do: message
  defp safe_provider_to_string(message), do: inspect(message, limit: 10, printable_limit: 200)

  # -- Help text -----------------------------------------------------------------

  @doc false
  @spec help_text() :: String.t()
  def help_text do
    """
    Usage: muse [options]

    Options:
      --repl            Use REPL CLI (default)
      --tui             Use TUI CLI (ExRatatui)
      --no-web          Disable web interface
      --web-only        Disable CLI, enable web only
      --no-cli          Alias for --web-only
      --port PORT       HTTP port (default: 4000)
      --host HOST       HTTP host (default: 127.0.0.1)
      --workspace PATH  Workspace directory
      --no-watch        Disable hot reload
      --verbose         Enable debug-level console logging (overrides TUI silence)
      --help, -h        Show this help
      --version, -v     Show version and exit
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

      current =
        current
        |> Keyword.put(:http, http)
        |> suppress_noisy_endpoint_opts(opts)

      Application.put_env(:muse, MuseWeb.Endpoint, current)
    end

    :ok
  end

  # In TUI mode, disable watchers (esbuild stdout) and live-reload
  # patterns so they don't print over the terminal.
  defp suppress_noisy_endpoint_opts(current, %{cli_ui: :tui}) do
    current
    |> Keyword.put(:watchers, [])
    |> Keyword.delete(:live_reload)
  end

  defp suppress_noisy_endpoint_opts(current, _opts), do: current

  # -- Configurable helpers (test-injectable) ------------------------------------

  defp start_runtime_children? do
    Application.get_env(:muse, :start_runtime_children?, true)
  end

  defp halt_fun do
    Application.get_env(:muse, :halt_fun, &System.halt/1)
  end

  @doc false
  @spec version_string() :: String.t()
  def version_string do
    case Application.spec(:muse, :vsn) do
      nil -> Application.get_env(:muse, :version, "0.1.0")
      charlist when is_list(charlist) -> List.to_string(charlist)
      other -> to_string(other)
    end
  end
end
