defmodule Muse.Prompt.Layer do
  @moduledoc """
  A single layer in the assembled prompt.

  Layers are ordered by `priority` (ascending = higher priority) and combined
  deterministically by `Muse.Prompt.Assembler`. Each layer carries metadata
  about its origin, visibility, kind, and estimated token count.

  ## Enforced keys

    * `:id`       — unique atom identifying this layer (e.g. `:muse_core_invariants`)
    * `:priority` — integer ordering key (lower = higher priority)
    * `:source`   — `:system | :muse_profile | :project | :user` — where this layer originates
    * `:content`  — the text content of the layer

  ## Visibility values

    * `:internal`     — not shown in normal debug views
    * `:debug_preview` — shown in developer debug preview (redacted)
    * `:user_visible` — safe to expose to users

  ## Kind values

    * `:instruction` — behavioral instruction
    * `:context`     — contextual information (project rules, memory, plan state)
    * `:user`        — user-provided input

  ## Redaction values

    * `:standard`   — apply full secret redaction
    * `:none`       — do not redact (for already-safe content like user messages)
  """

  @enforce_keys [:id, :priority, :source, :content]

  defstruct [
    :id,
    :title,
    :priority,
    :source,
    :content,
    visibility: :internal,
    kind: :instruction,
    token_estimate: nil,
    redaction: :standard,
    metadata: %{}
  ]

  @type id :: atom()
  @type source :: :system | :muse_profile | :project | :user
  @type visibility :: :internal | :debug_preview | :user_visible
  @type kind :: :instruction | :context | :user
  @type redaction :: :standard | :none

  @type t :: %__MODULE__{
          id: id(),
          title: String.t() | nil,
          priority: integer(),
          source: source(),
          content: String.t(),
          visibility: visibility(),
          kind: kind(),
          token_estimate: non_neg_integer() | nil,
          redaction: redaction(),
          metadata: map()
        }

  @doc """
  Create a new `%Layer{}` with validated enforced keys.

  Raises `ArgumentError` if any enforced key is missing.

  ## Examples

      iex> layer = Muse.Prompt.Layer.new!(id: :core, priority: 1, source: :system, content: "Be safe.")
      iex> layer.id
      :core

      iex> layer.priority
      1
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) when is_map(attrs) do
    struct!(__MODULE__, Map.take(attrs, [:id, :priority, :source, :content]))
    |> then(fn layer ->
      optional =
        Map.take(attrs, [
          :title,
          :visibility,
          :kind,
          :token_estimate,
          :redaction,
          :metadata
        ])

      Enum.reduce(optional, layer, fn {k, v}, acc ->
        %{acc | k => v}
      end)
    end)
  end

  def new!(attrs) when is_list(attrs) do
    new!(Map.new(attrs))
  end

  @doc """
  Estimate the token count for a layer's content.

  Uses a simple heuristic of ~4 characters per token, which is a reasonable
  approximation for English text across most LLM tokenizers. This is
  deterministic and does not require an external tokenizer.

  The estimate is stored in `token_estimate` if not already set.
  """
  @spec estimate_tokens(t()) :: non_neg_integer()
  def estimate_tokens(%__MODULE__{content: content}) when is_binary(content) do
    div(byte_size(content), 4)
  end

  def estimate_tokens(%__MODULE__{content: nil}), do: 0

  @doc """
  Return the layer with `token_estimate` populated if nil.
  """
  @spec with_token_estimate(t()) :: t()
  def with_token_estimate(%__MODULE__{token_estimate: nil} = layer) do
    %{layer | token_estimate: estimate_tokens(layer)}
  end

  def with_token_estimate(%__MODULE__{} = layer), do: layer
end
