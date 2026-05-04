defmodule Muse.Tools.ListSkills do
  @moduledoc """
  Read-only tool: list available skills.

  Returns an empty deterministic list if no skill system is active.
  This placeholder satisfies the Planning Muse profile's tool list
  without introducing a skill system dependency.
  """

  alias Muse.Tool.Result

  @doc """
  Execute the list_skills tool.

  Returns a `%Result{}` with an empty skills list.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(_args, _context) do
    Result.ok("list_skills", %{
      skills: [],
      count: 0
    })
  end
end
