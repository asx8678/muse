defmodule Muse.MuseProfile do
  @moduledoc """
  Struct representing a Muse profile — the identity, permissions, and
  capabilities of a specialized Muse within the runtime.

  ## Fields

    * `:id`                    — unique atom identifier (e.g. `:planning`, `:coding`)
    * `:display_name`          — human-facing name (e.g. `"Planning Muse"`)
    * `:description`           — short purpose statement
    * `:role`                  — atom categorising the Muse (e.g. `:planning`, `:coding`)
    * `:prompt`                — base prompt / role instruction text
    * `:system_prompt`          — assembled system prompt (populated by PromptAssembler)
    * `:tools`                 — list of tool name strings this Muse may invoke
    * `:allowed_tools`         — superset of tools permitted after approval (optional)
    * `:default_model`         — preferred LLM model identifier (optional)
    * `:output_schema`         — module atom or schema identifier for structured output
    * `:response_mode`         — atom such as `:plan`, `:patch`, `:text`
    * `:permissions`           — map of permission flags
    * `:handoff_targets`       — list of Muse `:id` atoms this Muse may hand off to
    * `:can_write?`            — whether the Muse may propose writes
    * `:requires_plan_approval?` — whether a plan must be approved before execution
    * `:style`                 — map of style/tone preferences

  **No `:name` field exists.** Use `:id` for internal references and
  `:display_name` for all user-facing text.

  ## Permissions map

  Common permission keys:

    * `:read`              — boolean
    * `:write`             — boolean | `:approval_required`
    * `:shell`             — boolean | `:approval_required`
    * `:network`           — boolean
    * `:can_create_plan`   — boolean
    * `:can_execute_plan`  — boolean

  """

  @enforce_keys [:id, :display_name, :role, :prompt, :tools]

  defstruct [
    :id,
    :display_name,
    :description,
    :role,
    :prompt,
    :system_prompt,
    :tools,
    :allowed_tools,
    :default_model,
    :output_schema,
    :response_mode,
    :permissions,
    :handoff_targets,
    :can_write?,
    :requires_plan_approval?,
    style: %{}
  ]

  @type id :: atom()

  @type permissions :: %{
          optional(:read) => boolean(),
          optional(:write) => boolean() | :approval_required,
          optional(:shell) => boolean() | :approval_required,
          optional(:network) => boolean(),
          optional(:can_create_plan) => boolean(),
          optional(:can_execute_plan) => boolean()
        }

  @type t :: %__MODULE__{
          id: id(),
          display_name: String.t(),
          description: String.t() | nil,
          role: atom(),
          prompt: String.t(),
          system_prompt: String.t() | nil,
          tools: [String.t()],
          allowed_tools: [String.t()] | nil,
          default_model: String.t() | nil,
          output_schema: module() | atom() | nil,
          response_mode: atom() | nil,
          permissions: permissions(),
          handoff_targets: [id()] | nil,
          can_write?: boolean() | nil,
          requires_plan_approval?: boolean() | nil,
          style: map()
        }

  @doc """
  Creates a new `%Muse.MuseProfile{}` from a keyword list or map.

  Enforced keys (`:id`, `:display_name`, `:role`, `:prompt`, `:tools`) must
  be present — otherwise raises `ArgumentError` (from `struct!/2`).
  Unknown keys (e.g. `:name`) are silently dropped to prevent leakage.

  ## Examples

      iex> Muse.MuseProfile.new!(id: :planning, display_name: "Planning Muse",
      ...>   role: :planning, prompt: "You are a planning muse.", tools: ["read_file"])
      %Muse.MuseProfile{id: :planning, display_name: "Planning Muse"}

  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) when is_map(attrs) do
    # Separate enforced keys (required by struct!) from optional struct keys.
    # Drop any keys not in the struct definition (e.g. :name) to prevent
    # them from being injected into the map.
    struct_keys =
      __MODULE__.__info__(:struct)
      |> Enum.map(fn
        %{field: f} -> f
        %{key: k} -> k
      end)
      |> MapSet.new()

    {enforced, optional} = Enum.split_with(attrs, fn {k, _} -> k in @enforce_keys end)
    safe_optional = Enum.filter(optional, fn {k, _} -> MapSet.member?(struct_keys, k) end)

    struct!(__MODULE__, Enum.into(enforced, []))
    |> then(fn profile ->
      Enum.reduce(safe_optional, profile, fn {key, value}, acc ->
        %{acc | key => value}
      end)
    end)
  end

  def new!(attrs) when is_list(attrs) do
    new!(Map.new(attrs))
  end

  @doc """
  Returns a map summary suitable for command output or JSON serialization.

  Includes `:id`, `:display_name`, `:role`, `:description`, `:tools`,
  and `:permissions` — no internal-only fields.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = profile) do
    %{
      id: profile.id,
      display_name: profile.display_name,
      role: profile.role,
      description: profile.description,
      tools: profile.tools,
      permissions: profile.permissions
    }
  end

  # -- Private ------------------------------------------------------------------
end
