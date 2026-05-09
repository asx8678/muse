defmodule Muse.Test.FakeToolRunner do
  @moduledoc """
  Deterministic offline fake tool runner for testing.

  Simulates `Muse.Tool.Runner.run/3` behavior without touching the
  filesystem, network, or real tool registry. Every call produces
  a predictable `%Muse.Tool.Result{}` based on the provided script
  or the default passthrough behavior.

  ## Usage

  Instead of calling `Muse.Tool.Runner.run/3` in tests, call

      Muse.Test.FakeToolRunner.run(tool_name, args, context)

  Or inject the fake runner into a context map and have the system
  dispatch through `FakeToolRunner.run/3` instead.

  ## Scripting via context

  Place a `:fake_tool_script` key in the context map:

      context = %{
        workspace: "/tmp",
        muse_id: :planning,
        fake_tool_script: %{
          "read_file" => {:ok, "file contents here"},
          "repo_search" => {:ok, %{results: [], total: 0}}
        }
      }

  Tools not in the script fall through to the default behavior
  (success with a placeholder output).

  ## Default behavior

  When no script is provided, the fake runner returns a successful
  result with a placeholder output for known tool names and an error
  for unknown tools.
  """

  alias Muse.Tool.Result

  # Tools the fake runner knows about
  @known_tools ~w(
    read_file list_files repo_search git_status git_diff_readonly
    test_runner patch_propose patch_apply rollback_checkpoint
    ask_user_question list_muses list_skills
  )

  @doc """
  Run a fake tool call with deterministic output.

  Returns `%Result{}` — same contract as `Muse.Tool.Runner.run/3`.
  """
  @spec run(String.t(), map(), map()) :: Result.t()
  def run(tool_name, args, context) when is_binary(tool_name) and is_map(args) and is_map(context) do
    script = Map.get(context, :fake_tool_script, %{})

    case Map.get(script, tool_name) do
      nil ->
        default_result(tool_name, args)

      {:ok, output} ->
        Result.ok(tool_name, output)

      {:error, reason} ->
        Result.error(tool_name, reason)

      {:blocked, reason} ->
        Result.blocked(tool_name, reason)

      output when is_map(output) or is_binary(output) ->
        Result.ok(tool_name, output)
    end
  end

  def run(tool_name, _args, _context) do
    Result.error(to_string(tool_name), "invalid tool call: tool_name must be a string")
  end

  @doc """
  Build a fake tool script map for injection into context.

  ## Example

      script = Muse.Test.FakeToolRunner.script(%{
        "read_file" => {:ok, %{content: "hello", path: "a.ex"}},
        "repo_search" => {:ok, %{results: [], total: 0, truncated: false}}
      })

      context = %{workspace: "/tmp", fake_tool_script: script}
      result = Muse.Test.FakeToolRunner.run("read_file", %{"path" => "a.ex"}, context)
  """
  @spec script(map()) :: map()
  def script(entries) when is_map(entries), do: entries

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp default_result(tool_name, _args) when tool_name in @known_tools do
    Result.ok(tool_name, %{fake: true, tool: tool_name})
  end

  defp default_result(tool_name, _args) do
    # Unknown tool — simulate the runner's behavior
    if tool_name in ~w(write_file shell_command network_call delete_file remote_exec) do
      Result.blocked(tool_name, "#{tool_name} is a blocked tool")
    else
      Result.error(tool_name, "unknown tool: #{tool_name}")
    end
  end
end
