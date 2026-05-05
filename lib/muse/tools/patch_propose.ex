defmodule Muse.Tools.PatchPropose do
  @moduledoc """
  Proposes a patch without applying it.

  The Coding Muse calls this tool to record a patch proposal (diff content,
  target files, and description). The proposal is stored in the session as
  `pending_patch` and the session transitions to `:awaiting_patch_approval`.

  **No files are written.** The handler is side-effect free; actual
  application requires explicit user approval (lane06).

  ## Arguments

    * `patch_content` — the diff/patch text (required)
    * `target_files`  — list of file paths the patch targets (optional)
    * `description`   — short summary of the change (optional)

  ## Integration points

  The ToolLoop detects successful `patch_propose` calls and captures the
  proposal in its result map under `:patch_proposals`. The Conductor then
  stores the proposal on the session and transitions to
  `:awaiting_patch_approval`. Full `/approve patch` command lifecycle is
  owned by lane06; this handler only records the proposal.
  """

  alias Muse.Tool.Result

  @doc """
  Execute a patch proposal — records the proposal without writing.

  Returns a success result with the proposal data so the ToolLoop and
  Conductor can capture it.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, _context) do
    patch_content = Map.get(args, "patch_content") || Map.get(args, :patch_content)
    target_files = Map.get(args, "target_files") || Map.get(args, :target_files) || []
    description = Map.get(args, "description") || Map.get(args, :description) || ""

    cond do
      is_nil(patch_content) or patch_content == "" ->
        Result.error("patch_propose", "missing required argument: patch_content")

      not is_list(target_files) ->
        Result.error("patch_propose", "target_files must be a list of file paths")

      true ->
        proposal = %{
          patch_content: patch_content,
          target_files: target_files,
          description: description
        }

        Result.ok(
          "patch_propose",
          %{
            status: "proposed",
            message: "Patch proposal recorded. Awaiting approval to apply.",
            target_files: target_files,
            description: description,
            content_length: String.length(patch_content)
          },
          %{patch_proposal: proposal}
        )
    end
  end
end
