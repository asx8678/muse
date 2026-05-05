defmodule Muse.Tool.Spec do
  @moduledoc """
  Tool specification struct describing a tool's identity, schema, permissions,
  and handler module.

  Each tool in the Muse system is described by a `%Spec{}`. The registry builds
  these at compile time; the runner validates calls against them before
  dispatching to the handler module.

  ## Provider schema

  `to_provider_schema/1` converts a `%Spec{}` into an OpenAI-compatible
  function-definition map suitable for inclusion in LLM requests:

      %{
        "type" => "function",
        "function" => %{
          "name" => "read_file",
          "description" => "Read the contents of a file...",
          "parameters" => %{...}
        }
      }

  A top-level `:name` key is also included for debug-preview compatibility.
  """

  @enforce_keys [:name, :description, :handler, :input_schema]

  defstruct [
    :name,
    :description,
    :handler,
    :input_schema,
    kind: :read,
    risk: :low,
    permission: :read,
    visibility: :user,
    allowed_roles: [:planning, :coding],
    allowed_muses: [:planning, :coding],
    requires_approval: false,
    emits_events: true,
    output_limit: 50_000
  ]

  @type kind :: :read | :write | :shell | :network | :delete | :interactive | :patch
  @type risk :: :low | :medium | :high | :critical
  @type permission ::
          :read
          | :write
          | :shell
          | :network
          | :delete
          | :interactive
          | :patch
          | :test
          | :restore_checkpoint
  @type visibility :: :user | :internal

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          handler: module(),
          input_schema: map(),
          kind: kind(),
          risk: risk(),
          permission: permission(),
          visibility: visibility(),
          allowed_roles: [atom()],
          allowed_muses: [atom()],
          requires_approval: boolean(),
          emits_events: boolean(),
          output_limit: pos_integer()
        }

  @doc """
  Create a new `%Spec{}` with validated enforced keys.

  Raises `ArgumentError` if any enforced key is missing.

  ## Examples

      iex> spec = Muse.Tool.Spec.new!(name: "read_file", description: "Read a file",
      ...>   handler: Muse.Tools.ReadFile, input_schema: %{})
      iex> spec.name
      "read_file"

  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) when is_map(attrs) do
    enforced = Map.take(attrs, [:name, :description, :handler, :input_schema])

    struct!(__MODULE__, enforced)
    |> then(fn spec ->
      optional =
        Map.take(attrs, [
          :kind,
          :risk,
          :permission,
          :visibility,
          :allowed_roles,
          :allowed_muses,
          :requires_approval,
          :emits_events,
          :output_limit
        ])

      Enum.reduce(optional, spec, fn {k, v}, acc -> %{acc | k => v} end)
    end)
  end

  def new!(attrs) when is_list(attrs), do: new!(Map.new(attrs))

  @doc """
  Convert a `%Spec{}` to an OpenAI-compatible function-definition map.

  The output includes a top-level `:name` key for debug-preview compatibility
  alongside the standard `:type` and `:function` structure.

  ## Examples

      iex> spec = Muse.Tool.Spec.new!(name: "read_file", description: "Read a file",
      ...>   handler: Muse.Tools.ReadFile, input_schema: %{type: "object", properties: %{path: %{type: "string"}}})
      iex> schema = Muse.Tool.Spec.to_provider_schema(spec)
      iex> schema[:name]
      "read_file"
      iex> schema["type"]
      "function"
      iex> schema["function"]["name"]
      "read_file"

  """
  @spec to_provider_schema(t()) :: map()
  def to_provider_schema(%__MODULE__{} = spec) do
    %{
      "type" => "function",
      "function" => %{
        "name" => spec.name,
        "description" => spec.description,
        "parameters" => spec.input_schema
      },
      :name => spec.name
    }
  end
end
