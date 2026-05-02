defmodule Mix.Tasks.Muse do
  @shortdoc "Start Muse coding agent"

  @moduledoc """
  Starts the Muse coding agent from source via `mix muse`.

  Stashes argv, marks `:source_mode?` as `true`, starts the `:muse`
  application, and blocks forever (the real work happens in supervised
  processes).

  ## Usage

      mix muse [--no-web] [--web-only] [--port 4100] [--host 0.0.0.0] [--workspace /path]

  Delegates to `Muse.CLI.Main.boot/3` so the core boot logic is tested
  in one place.
  """

  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: no_return()
  def run(args) do
    Muse.CLI.Main.boot(args, true, &Process.sleep/1)
  end
end
