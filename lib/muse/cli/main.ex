defmodule Muse.CLI.Main do
  @moduledoc """
  Escript entrypoint for Muse.

  When Muse is built as an escript (`mix escript.build && ./muse`), this
  module's `main/1` is the first function called. It stashes argv into
  the application environment, marks `:source_mode?` as `false`, starts
  the `:muse` application, and then sleeps forever (the real work happens
  in supervised processes).

  For testability, the core boot logic lives in `boot/3`; `main/1` is a
  thin wrapper that delegates to it with `Process.sleep/1` as the sleep
  function.
  """

  @doc """
  Escript entrypoint. Delegates to `boot/3` with infinite sleep.
  """
  @spec main([String.t()]) :: no_return()
  def main(args) do
    boot(args, false, &Process.sleep/1)
  end

  @doc """
  Core boot logic shared by the escript entrypoint and the Mix task.

  - Stashes `args` under `:muse` → `:boot_args` so `Muse.Argv.get/0` works.
  - Sets `:muse` → `:source_mode?` to `source_mode?` (false for escript,
    true for `mix muse`).
  - Ensures the `:muse` application (and all dependencies) are started.
  - Calls `sleep_fun.(:infinity)` to block the calling process forever.

  The `sleep_fun` parameter exists solely so tests can substitute a
  no-op or short sleep without hanging the test process.
  """
  @spec boot([String.t()], boolean(), (:infinity -> no_return())) ::
          {:ok, [atom()]} | {:error, term()}
  def boot(args, source_mode?, sleep_fun) do
    Application.put_env(:muse, :boot_args, args)
    Application.put_env(:muse, :source_mode?, source_mode?)

    # Handle --help / -h before starting the application to avoid
    # unnecessary dependency startup warnings.
    if is_help_request?(args) do
      print_help()
      System.halt(0)
    end

    # Handle --version / -v before starting the application to avoid
    # unnecessary dependency startup warnings.
    if is_version_request?(args) do
      IO.puts("muse #{Muse.Application.version_string()}")
      System.halt(0)
    end

    result = Application.ensure_all_started(:muse)

    sleep_fun.(:infinity)

    # Unreachable — sleep_fun(:infinity) never returns — but keeps the
    # type spec honest for callers that pattern-match on the result.
    result
  end

  @doc false
  @spec is_version_request?([String.t()]) :: boolean()
  def is_version_request?(args) do
    "--version" in args or "-v" in args
  end

  @doc false
  @spec is_help_request?([String.t()]) :: boolean()
  def is_help_request?(args) do
    "--help" in args or "-h" in args or "help" in args
  end

  @doc false
  @spec print_help() :: :ok
  def print_help do
    IO.puts("""
    muse - Local coding runtime for Muse

    USAGE
        muse [OPTIONS]
        mix muse [OPTIONS]

    OPTIONS
        --version, -v    Print version and exit
        --help, -h       Print this help and exit
        --repl           Start interactive REPL (default when no TUI)
        --tui            Start terminal UI (ExRatatui)
        --no-web         Disable web interface
        --web-only       Web interface only (no REPL/TUI)
        --port PORT      Web interface port (default: 4000)
        --host HOST      Web interface host (default: 127.0.0.1)
        --workspace DIR  Workspace root directory
        --verbose        Enable verbose logging

    INTERFACE COMMANDS (in REPL/TUI/Web)
        /help            Show available slash commands
        /muses           List available Muses (Planning, Coding, etc.)
        /plan            Show active Muse Plan
        /approve plan    Approve the active plan (no implementation starts)
        /reject plan     Reject the active plan and request revision
        /session         Show session status, active plan, pending patch
        /quit            Exit REPL/TUI

    SAFETY
        All write/shell/network actions require explicit approval.
        Remote execution is denied by default.
        Fake provider is the default; no API keys required.

    DOCUMENTATION
        https://github.com/your-org/muse (update URL)
    """)

    :ok
  end
end
