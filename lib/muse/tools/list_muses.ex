defmodule Muse.Tools.ListMuses do
  @moduledoc """
  Read-only tool: list available Muse profiles with safe summaries.

  Returns a list of maps containing id, display_name, role, description,
  tools, and permissions — no internal-only or sensitive fields.
  """

  alias Muse.Tool.Result

  @doc """
  Execute the list_muses tool.

  Returns a `%Result{}` with safe Muse summaries.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(_args, _context) do
    summaries = Muse.MuseRegistry.summaries()

    Result.ok("list_muses", %{
      muses: summaries,
      count: length(summaries)
    })
  end
end
