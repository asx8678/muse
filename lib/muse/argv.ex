defmodule Muse.Argv do
  @moduledoc """
  Reusable access to boot-time argv.

  In source mode (`mix muse`), args are stashed in `:muse` → `:boot_args`
  before the application starts.  In escript mode, `System.argv/0` is the
  source of truth.  This helper hides the difference so callers never have
  to think about it.
  """

  @spec get() :: [String.t()]
  def get do
    Application.get_env(:muse, :boot_args, System.argv())
  end
end
