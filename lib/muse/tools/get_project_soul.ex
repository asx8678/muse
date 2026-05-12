defmodule Muse.Tools.GetProjectSoul do
  @moduledoc """
  Read-only tool: return the project-level architecture summary.

  Returns `Muse.MatrixManager.project_soul/0` — a concise (~500 word)
  description of the project purpose, structure, key modules, and
  dependency links. This is also injected into the Planner's system
  prompt on mode entry.

  ## Output format

      %{
        soul: "Project at my_app: 42 indexed files, 15 modules...",
        indexed: true
      }
  """

  alias Muse.Tool.Result

  @doc """
  Execute the get_project_soul tool.

  No arguments required.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(_args, _context) do
    case Process.whereis(Muse.MatrixManager) do
      nil ->
        Result.error("get_project_soul", "matrix manager not available")

      _pid ->
        soul = Muse.MatrixManager.project_soul()
        indexed = soul != ""

        Result.ok("get_project_soul", %{
          soul: soul,
          indexed: indexed
        })
    end
  end
end
