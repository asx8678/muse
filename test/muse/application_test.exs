defmodule Muse.ApplicationTest do
  use ExUnit.Case, async: false

  alias Muse.{BootOptions, StartupBanner}

  # Use full module name to avoid shadowing Elixir.Application
  @app_mod Muse.Application

  # -- Helpers -------------------------------------------------------------------

  defp boot_opts(overrides \\ []) do
    defaults = [
      workspace: "/tmp/muse_test",
      cli?: true,
      cli_ui: :repl,
      web?: true,
      host: "127.0.0.1",
      port: 4000,
      watch?: true,
      help?: false,
      verbose?: false
    ]

    struct!(BootOptions, Keyword.merge(defaults, overrides))
  end

  defp child_ids(children) do
    Enum.map(children, fn
      {mod, opts} when is_list(opts) -> mod
      {mod, _} -> mod
      mod when is_atom(mod) -> mod
    end)
  end

  defp with_env(key, value, fun) do
    original = Elixir.Application.get_env(:muse, key)
    Elixir.Application.put_env(:muse, key, value)

    try do
      fun.()
    after
      if original do
        Elixir.Application.put_env(:muse, key, original)
      else
        Elixir.Application.delete_env(:muse, key)
      end
    end
  end

  # -- runtime_children/1 -------------------------------------------------------

  describe "runtime_children/1 — default (CLI + Web + watch + source_mode)" do
    test "includes Task.Supervisor, PubSub, SessionRegistry, SessionSupervisor, Diagnostics, SelfHealingQueue, Workspace, State, CLI.Repl, Endpoint, DevReloader" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts())
        ids = child_ids(children)

        # Task.Supervisor child is {Task.Supervisor, name: Muse.TaskSupervisor}
        assert Task.Supervisor in ids
        assert Phoenix.PubSub in ids
        assert Muse.SessionRegistry in ids
        assert Muse.SessionSupervisor in ids
        assert Muse.Diagnostics in ids
        assert Muse.SelfHealingQueue in ids
        assert Muse.Workspace in ids
        assert Muse.State in ids
        assert Muse.CLI.Repl in ids
        assert MuseWeb.Endpoint in ids
        assert Muse.DevReloader in ids
      end)
    end

    test "Task.Supervisor is first child" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts())
        {mod, _opts} = hd(children)
        assert mod == Task.Supervisor
      end)
    end

    test "SessionRegistry/Supervisor starts after PubSub and before Diagnostics; SelfHealingQueue after Diagnostics" do
      with_env(:source_mode?, true, fn ->
        ids = @app_mod.runtime_children(boot_opts()) |> child_ids()

        pubsub_index = Enum.find_index(ids, &(&1 == Phoenix.PubSub))
        registry_index = Enum.find_index(ids, &(&1 == Muse.SessionRegistry))
        supervisor_index = Enum.find_index(ids, &(&1 == Muse.SessionSupervisor))
        diagnostics_index = Enum.find_index(ids, &(&1 == Muse.Diagnostics))
        self_healing_index = Enum.find_index(ids, &(&1 == Muse.SelfHealingQueue))
        workspace_index = Enum.find_index(ids, &(&1 == Muse.Workspace))
        state_index = Enum.find_index(ids, &(&1 == Muse.State))

        assert pubsub_index < registry_index
        assert registry_index < supervisor_index
        assert supervisor_index < diagnostics_index
        assert diagnostics_index < self_healing_index
        assert self_healing_index < workspace_index
        assert self_healing_index < state_index
      end)
    end

    test "Workspace child_spec uses boot option workspace root" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts(workspace: "/custom/path"))
        workspace_spec = Enum.find(children, &match?({Muse.Workspace, _}, &1))
        assert {Muse.Workspace, root: "/custom/path"} = workspace_spec
      end)
    end

    test "Endpoint child_spec has server: true" do
      with_env(:source_mode?, false, fn ->
        children =
          @app_mod.runtime_children(
            boot_opts(cli?: false, cli_ui: :none, host: "0.0.0.0", port: 8080)
          )

        endpoint_spec = Enum.find(children, &match?({MuseWeb.Endpoint, _}, &1))
        assert {MuseWeb.Endpoint, opts} = endpoint_spec
        assert Keyword.get(opts, :server) == true
      end)
    end

    test "LogBuffer child receives configured buffer logger level" do
      with_env(:logger, [buffer_level: :debug, console_level: :warning], fn ->
        children = @app_mod.runtime_children(boot_opts())
        log_buffer_spec = Enum.find(children, &match?({Muse.LogBuffer, _}, &1))

        assert {Muse.LogBuffer, opts} = log_buffer_spec
        assert Keyword.get(opts, :install_logger_handler?) == true
        assert Keyword.get(opts, :logger_level) == :debug
      end)
    end
  end

  describe "runtime_children/1 — --no-web" do
    test "excludes Endpoint" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts(web?: false))
        ids = child_ids(children)

        assert MuseWeb.Endpoint not in ids
      end)
    end

    test "still includes CLI.Repl by default" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts(web?: false))
        ids = child_ids(children)

        assert Muse.CLI.Repl in ids
      end)
    end
  end

  describe "runtime_children/1 --web-only / --no-cli" do
    test "excludes CLI children (none ui)" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts(cli?: false, cli_ui: :none))
        ids = child_ids(children)

        assert Muse.CLI.Repl not in ids
        assert Muse.CLI.Tui not in ids
      end)
    end

    test "includes Endpoint" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts(cli?: false, cli_ui: :none, web?: true))
        ids = child_ids(children)

        assert MuseWeb.Endpoint in ids
      end)
    end
  end

  describe "runtime_children/1 — --tui" do
    test "includes CLI.Tui instead of CLI.Repl" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts(cli_ui: :tui))
        ids = child_ids(children)

        assert Muse.CLI.Tui in ids
        assert Muse.CLI.Repl not in ids
      end)
    end

    test "Tui child_spec has halt?, workspace, and web_url" do
      with_env(:source_mode?, false, fn ->
        children = @app_mod.runtime_children(boot_opts(cli_ui: :tui, workspace: "/tmp/proj"))
        tui_spec = Enum.find(children, &match?({Muse.CLI.Tui, _}, &1))
        assert {Muse.CLI.Tui, opts} = tui_spec
        assert Keyword.get(opts, :halt?) == true
        assert Keyword.get(opts, :workspace) == "/tmp/proj"
        assert Keyword.get(opts, :web_url) == "http://127.0.0.1:4000"
      end)
    end

    test "Tui child_spec web_url is nil when web? is false" do
      with_env(:source_mode?, false, fn ->
        children = @app_mod.runtime_children(boot_opts(cli_ui: :tui, web?: false))
        tui_spec = Enum.find(children, &match?({Muse.CLI.Tui, _}, &1))
        assert {Muse.CLI.Tui, opts} = tui_spec
        assert Keyword.get(opts, :web_url) == nil
      end)
    end
  end

  describe "runtime_children/1 — --no-watch" do
    test "excludes DevReloader" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts(watch?: false))
        ids = child_ids(children)

        assert Muse.DevReloader not in ids
      end)
    end
  end

  describe "runtime_children/1 — source_mode false disables DevReloader" do
    test "DevReloader excluded even when watch? is true and source_mode is false" do
      with_env(:source_mode?, false, fn ->
        children = @app_mod.runtime_children(boot_opts(watch?: true))
        ids = child_ids(children)

        assert Muse.DevReloader not in ids
      end)
    end
  end

  describe "runtime_children/1 — workspace root" do
    test "uses workspace from boot options" do
      with_env(:source_mode?, true, fn ->
        children = @app_mod.runtime_children(boot_opts(workspace: "/tmp/my-project"))
        workspace_spec = Enum.find(children, &match?({Muse.Workspace, _}, &1))
        assert {Muse.Workspace, root: "/tmp/my-project"} = workspace_spec
      end)
    end
  end

  # -- base_children/0 -----------------------------------------------------------

  describe "base_children/0" do
    test "includes PubSub, SessionRegistry, SessionSupervisor, and TaskSupervisor" do
      children = @app_mod.base_children()
      ids = child_ids(children)

      assert {Task.Supervisor, name: Muse.TaskSupervisor} in children
      assert Phoenix.PubSub in ids
      assert Muse.SessionRegistry in ids
      assert Muse.SessionSupervisor in ids
      assert length(ids) == 4
    end
  end

  # -- parse_host/1 --------------------------------------------------------------

  describe "parse_host/1" do
    test "parses 127.0.0.1 to tuple" do
      assert @app_mod.parse_host("127.0.0.1") == {127, 0, 0, 1}
    end

    test "parses 0.0.0.0 to tuple" do
      assert @app_mod.parse_host("0.0.0.0") == {0, 0, 0, 0}
    end

    test "parses 192.168.1.1 to tuple" do
      assert @app_mod.parse_host("192.168.1.1") == {192, 168, 1, 1}
    end

    test "returns localhost fallback for unparseable host" do
      assert @app_mod.parse_host("not-an-ip") == {127, 0, 0, 1}
    end

    test "returns localhost fallback for empty string" do
      assert @app_mod.parse_host("") == {127, 0, 0, 1}
    end
  end

  # -- help_text/0 ----------------------------------------------------------------

  describe "help_text/0" do
    test "contains usage header" do
      assert @app_mod.help_text() =~ "Usage: muse"
    end

    test "lists --no-web flag" do
      assert @app_mod.help_text() =~ "--no-web"
    end

    test "lists --web-only flag" do
      assert @app_mod.help_text() =~ "--web-only"
    end

    test "lists --help flag" do
      assert @app_mod.help_text() =~ "--help"
    end

    test "lists --tui flag" do
      assert @app_mod.help_text() =~ "--tui"
    end

    test "lists --verbose flag" do
      assert @app_mod.help_text() =~ "--verbose"
    end
  end

  # -- banner_opts/1 -------------------------------------------------------------

  describe "banner_opts/1" do
    test "returns keyword list with workspace, web?, ui, and logs" do
      opts = boot_opts(workspace: "/tmp/test-proj")
      banner = @app_mod.banner_opts(opts)

      assert Keyword.get(banner, :workspace) == "/tmp/test-proj"
      assert Keyword.get(banner, :web?) == true
      assert Keyword.get(banner, :ui) == :repl
      assert Keyword.get(banner, :logs) in [:debug, :warning]
    end

    test "ui is :none when cli_ui is :none" do
      opts = boot_opts(cli?: false, cli_ui: :none)
      banner = @app_mod.banner_opts(opts)

      assert Keyword.get(banner, :ui) == :none
    end

    test "ui is :repl when cli_ui is :repl" do
      opts = boot_opts(cli?: true, cli_ui: :repl)
      banner = @app_mod.banner_opts(opts)

      assert Keyword.get(banner, :ui) == :repl
    end

    test "ui is :tui when cli_ui is :tui" do
      opts = boot_opts(cli?: true, cli_ui: :tui)
      banner = @app_mod.banner_opts(opts)

      assert Keyword.get(banner, :ui) == :tui
    end

    test "watch? reflects effective state (watch? AND source_mode?)" do
      opts = boot_opts(watch?: true)

      with_env(:source_mode?, true, fn ->
        assert @app_mod.banner_opts(opts)[:watch?] == true
      end)

      with_env(:source_mode?, false, fn ->
        assert @app_mod.banner_opts(opts)[:watch?] == false
      end)
    end

    test "watch? false stays false even with source_mode true" do
      opts = boot_opts(watch?: false)

      with_env(:source_mode?, true, fn ->
        assert @app_mod.banner_opts(opts)[:watch?] == false
      end)
    end

    test "logs is :debug when verbose? is true" do
      opts = boot_opts(verbose?: true)
      assert @app_mod.banner_opts(opts)[:logs] == :debug
    end

    test "logs falls back to console_level when verbose? is false" do
      with_env(:logger, [console_level: :error], fn ->
        opts = boot_opts(verbose?: false)
        assert @app_mod.banner_opts(opts)[:logs] == :error
      end)
    end

    test "verbose? true overrides console_level to :debug even with :tui" do
      with_env(:logger, [console_level: :warning], fn ->
        opts = boot_opts(verbose?: true, cli_ui: :tui)
        assert @app_mod.banner_opts(opts)[:logs] == :debug
        assert @app_mod.banner_opts(opts)[:ui] == :tui
      end)
    end
  end

  # -- effective_watch?/1 --------------------------------------------------------

  describe "effective_watch?/1" do
    test "true when watch? true and source_mode? true" do
      with_env(:source_mode?, true, fn ->
        assert @app_mod.effective_watch?(boot_opts(watch?: true)) == true
      end)
    end

    test "false when watch? true but source_mode? false" do
      with_env(:source_mode?, false, fn ->
        assert @app_mod.effective_watch?(boot_opts(watch?: true)) == false
      end)
    end

    test "false when watch? false regardless of source_mode?" do
      with_env(:source_mode?, true, fn ->
        assert @app_mod.effective_watch?(boot_opts(watch?: false)) == false
      end)
    end
  end

  # -- Banner integration with StartupBanner -------------------------------------

  describe "banner integration" do
    test "banner_opts with --no-web produces 'web=off'" do
      opts = boot_opts(web?: false)
      banner_kw = @app_mod.banner_opts(opts)
      banner = StartupBanner.format(banner_kw)

      refute banner =~ "\n"
      assert banner =~ "web=off"
    end

    test "banner_opts with --no-cli produces 'ui=none'" do
      opts = boot_opts(cli?: false, cli_ui: :none)
      banner_kw = @app_mod.banner_opts(opts)
      banner = StartupBanner.format(banner_kw)

      assert banner =~ "ui=none"
    end

    test "banner_opts with --tui produces 'ui=tui'" do
      opts = boot_opts(cli_ui: :tui)
      banner_kw = @app_mod.banner_opts(opts)
      banner = StartupBanner.format(banner_kw)

      assert banner =~ "ui=tui"
    end

    test "banner_opts with --verbose --tui produces 'ui=tui' and 'logs=debug+'" do
      opts = boot_opts(verbose?: true, cli_ui: :tui)
      banner_kw = @app_mod.banner_opts(opts)
      banner = StartupBanner.format(banner_kw)

      assert banner =~ "ui=tui"
      assert banner =~ "logs=debug+"
    end

    test "banner_opts with --no-watch produces 'reload=off'" do
      opts = boot_opts(watch?: false)
      banner_kw = @app_mod.banner_opts(opts)
      banner = StartupBanner.format(banner_kw)

      assert banner =~ "reload=off"
    end

    test "banner_opts with source_mode false shows 'reload=off'" do
      opts = boot_opts(watch?: true)

      with_env(:source_mode?, false, fn ->
        banner_kw = @app_mod.banner_opts(opts)
        banner = StartupBanner.format(banner_kw)

        assert banner =~ "reload=off"
      end)
    end

    test "banner_opts default shows full enabled one-line banner" do
      with_env(:source_mode?, true, fn ->
        opts = boot_opts()
        banner_kw = @app_mod.banner_opts(opts)
        banner = StartupBanner.format(banner_kw)

        refute banner =~ "\n"
        assert banner =~ "ui=repl"
        assert banner =~ "web=http://127.0.0.1:4000"
        assert banner =~ "reload=on"
        assert banner =~ "logs="
      end)
    end
  end

  # -- maybe_configure_endpoint/1 -----------------------------------------------

  describe "maybe_configure_endpoint/1" do
    setup do
      original = Elixir.Application.get_env(:muse, MuseWeb.Endpoint)
      on_exit(fn -> Elixir.Application.put_env(:muse, MuseWeb.Endpoint, original) end)
      :ok
    end

    test "sets http ip and port in app env when web? is true" do
      opts = boot_opts(web?: true, host: "0.0.0.0", port: 8080)
      @app_mod.maybe_configure_endpoint(opts)

      http = Elixir.Application.get_env(:muse, MuseWeb.Endpoint)[:http]
      assert Keyword.get(http, :ip) == {0, 0, 0, 0}
      assert Keyword.get(http, :port) == 8080
    end

    test "does not modify app env when web? is false" do
      original_http = Elixir.Application.get_env(:muse, MuseWeb.Endpoint)[:http]
      opts = boot_opts(web?: false)
      @app_mod.maybe_configure_endpoint(opts)

      http = Elixir.Application.get_env(:muse, MuseWeb.Endpoint)[:http]
      assert http == original_http
    end

    test "in REPL mode preserves watchers and live_reload" do
      current = [
        http: [ip: {127, 0, 0, 1}, port: 4000],
        watchers: [esbuild: {Esbuild, :install_and_run, [:default, ["--watch"]]}],
        live_reload: [patterns: [~r"assets/.*(js|css)$"]]
      ]

      Elixir.Application.put_env(:muse, MuseWeb.Endpoint, current)
      opts = boot_opts(cli_ui: :repl, web?: true)
      @app_mod.maybe_configure_endpoint(opts)

      endpoint = Elixir.Application.get_env(:muse, MuseWeb.Endpoint)
      assert Keyword.get(endpoint, :watchers) != []
      assert Keyword.get(endpoint, :live_reload) != nil
    end

    test "in TUI mode clears watchers and deletes live_reload" do
      current = [
        http: [ip: {127, 0, 0, 1}, port: 4000],
        watchers: [esbuild: {Esbuild, :install_and_run, [:default, ["--watch"]]}],
        live_reload: [patterns: [~r"assets/.*(js|css)$"]]
      ]

      Elixir.Application.put_env(:muse, MuseWeb.Endpoint, current)
      opts = boot_opts(cli_ui: :tui, web?: true)
      @app_mod.maybe_configure_endpoint(opts)

      endpoint = Elixir.Application.get_env(:muse, MuseWeb.Endpoint)
      assert Keyword.get(endpoint, :watchers) == []
      assert Keyword.get(endpoint, :live_reload) == nil
    end

    test "in TUI mode still sets http ip and port" do
      current = [
        http: [ip: {0, 0, 0, 0}, port: 3000],
        watchers: [esbuild: {Esbuild, :install_and_run, [:default, ["--watch"]]}]
      ]

      Elixir.Application.put_env(:muse, MuseWeb.Endpoint, current)
      opts = boot_opts(cli_ui: :tui, host: "0.0.0.0", port: 8080, web?: true)
      @app_mod.maybe_configure_endpoint(opts)

      http = Elixir.Application.get_env(:muse, MuseWeb.Endpoint)[:http]
      assert Keyword.get(http, :ip) == {0, 0, 0, 0}
      assert Keyword.get(http, :port) == 8080
    end
  end

  # -- Application start/stop integration ----------------------------------------

  describe "application start integration" do
    setup do
      original_keys = [:start_runtime_children?, :source_mode?, :boot_args, :halt_fun]

      originals =
        Enum.map(original_keys, fn k -> {k, Elixir.Application.get_env(:muse, k)} end)

      on_exit(fn ->
        Muse.Diagnostics.LoggerHandler.remove()

        Enum.each(originals, fn {k, v} ->
          case v do
            nil -> Elixir.Application.delete_env(:muse, k)
            val -> Elixir.Application.put_env(:muse, k, val)
          end
        end)
      end)

      :ok
    end

    test "starts runtime children and Muse.submit/2 routes through a session" do
      Elixir.Application.put_env(:muse, :start_runtime_children?, true)
      Elixir.Application.put_env(:muse, :source_mode?, false)
      Elixir.Application.put_env(:muse, :boot_args, ["--web-only", "--no-watch"])
      Elixir.Application.put_env(:muse, :halt_fun, fn _ -> :ok end)

      # Stop the app first
      Elixir.Application.stop(:muse)
      Process.sleep(50)

      {:ok, _} = Elixir.Application.ensure_all_started(:muse)

      # Verify expected processes are running
      assert Process.whereis(Muse.TaskSupervisor) != nil
      assert Process.whereis(Muse.PubSub) != nil
      assert Process.whereis(Muse.SessionRegistry) != nil
      assert Process.whereis(Muse.SessionSupervisor) != nil
      assert Process.whereis(Muse.Diagnostics) != nil
      assert Process.whereis(Muse.SelfHealingQueue) != nil
      assert Process.whereis(Muse.Workspace) != nil
      assert Process.whereis(Muse.State) != nil
      assert Process.whereis(MuseWeb.Endpoint) != nil

      assert {:ok, text} = Muse.submit(:cli, "runtime smoke")
      assert text =~ "Placeholder response"
      assert {:ok, %{session_id: "default", event_count: 12}} = Muse.SessionRouter.status()

      # CLI should NOT be running (web-only)
      assert Process.whereis(Muse.CLI.Repl) == nil

      # DevReloader should NOT be running (no-watch + source_mode false)
      assert Process.whereis(Muse.DevReloader) == nil

      # Cleanup: stop the app and restore minimal mode
      Elixir.Application.stop(:muse)
      Process.sleep(50)
      Elixir.Application.put_env(:muse, :start_runtime_children?, false)
      Elixir.Application.delete_env(:muse, :boot_args)
      Elixir.Application.delete_env(:muse, :halt_fun)
      Elixir.Application.ensure_all_started(:muse)
    end

    test "starts with --web-only --no-watch --port 4002: Endpoint on custom port" do
      Elixir.Application.put_env(:muse, :start_runtime_children?, true)
      Elixir.Application.put_env(:muse, :source_mode?, false)

      Elixir.Application.put_env(:muse, :boot_args, ["--web-only", "--no-watch", "--port", "4002"])

      Elixir.Application.put_env(:muse, :halt_fun, fn _ -> :ok end)

      Elixir.Application.stop(:muse)
      Process.sleep(50)

      {:ok, _} = Elixir.Application.ensure_all_started(:muse)

      assert Process.whereis(MuseWeb.Endpoint) != nil

      # Cleanup
      Elixir.Application.stop(:muse)
      Process.sleep(50)
      Elixir.Application.put_env(:muse, :start_runtime_children?, false)
      Elixir.Application.delete_env(:muse, :boot_args)
      Elixir.Application.delete_env(:muse, :halt_fun)
      Elixir.Application.ensure_all_started(:muse)
    end

    test "base mode (start_runtime_children? false) starts PubSub and session routing infrastructure" do
      # The default test config has start_runtime_children? = false
      # so after a fresh app start, only base routing infrastructure should be running.
      Elixir.Application.stop(:muse)
      Process.sleep(50)

      Elixir.Application.put_env(:muse, :start_runtime_children?, false)
      {:ok, _} = Elixir.Application.ensure_all_started(:muse)

      assert Process.whereis(Muse.PubSub) != nil
      assert Process.whereis(Muse.SessionRegistry) != nil
      assert Process.whereis(Muse.SessionSupervisor) != nil
      # TaskSupervisor is now part of base_children (needed by TurnRunner)
      assert Process.whereis(Muse.TaskSupervisor) != nil
      # These should NOT be running under base mode
      assert Process.whereis(Muse.Diagnostics) == nil
      assert Process.whereis(Muse.Workspace) == nil
      assert Process.whereis(Muse.State) == nil

      # Restore
      Elixir.Application.stop(:muse)
      Process.sleep(50)
      Elixir.Application.ensure_all_started(:muse)
    end
  end
end
