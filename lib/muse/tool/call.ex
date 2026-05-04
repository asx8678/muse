defmodule Muse.Tool.Call do
  @moduledoc """
  Struct representing a tool invocation context.

  Created by the runner before dispatching to a handler. Carries all
  the information a handler needs: the resolved tool spec, validated
  arguments, and the execution context (workspace, muse profile, session).

  ## Fields

    * `:id`           — unique call identifier (e.g. `"tc_a1b2c3"`)
    * `:tool_name`    — the tool name string
    * `:spec`         — the `Muse.Tool.Spec.t()` for this tool
    * `:arguments`    — validated argument map
    * `:workspace`    — workspace root path
    * `:muse_id`      — the requesting Muse profile id atom
    * `:session_id`   — session identifier
    * `:turn_id`      — turn identifier
  """

  @enforce_keys [:id, :tool_name, :spec, :arguments, :workspace]

  defstruct [
    :id,
    :tool_name,
    :spec,
    :arguments,
    :workspace,
    :muse_id,
    :session_id,
    :turn_id
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          tool_name: String.t(),
          spec: Muse.Tool.Spec.t(),
          arguments: map(),
          workspace: String.t(),
          muse_id: atom() | nil,
          session_id: String.t() | nil,
          turn_id: String.t() | nil
        }

  @doc """
  Create a new `%Call{}` struct.

  ## Examples

      iex> call = Muse.Tool.Call.new(id: "tc_1", tool_name: "read_file",
      ...>   spec: %Muse.Tool.Spec{}, arguments: %{}, workspace: "/tmp/project")
      iex> call.id
      "tc_1"

  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__, Keyword.take(attrs, [:id, :tool_name, :spec, :arguments, :workspace]))
    |> then(fn call ->
      optional = Keyword.take(attrs, [:muse_id, :session_id, :turn_id])
      Enum.reduce(optional, call, fn {k, v}, acc -> %{acc | k => v} end)
    end)
  end
end
