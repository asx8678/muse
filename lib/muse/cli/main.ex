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

    result = Application.ensure_all_started(:muse)

    sleep_fun.(:infinity)

    # Unreachable — sleep_fun(:infinity) never returns — but keeps the
    # type spec honest for callers that pattern-match on the result.
    result
  end
end
