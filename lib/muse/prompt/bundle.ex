defmodule Muse.Prompt.Bundle do
  @moduledoc """
  An assembled prompt bundle containing all layers, messages, and tool specs
  ready for provider conversion.

  Built by `Muse.Prompt.Assembler.build/4` and consumed by
  `Muse.Prompt.ModelPreparer.to_request/3`.

  ## Enforced keys

    * `:session_id` — the session this bundle belongs to
    * `:muse_id`   — the active Muse profile id
    * `:layers`    — ordered list of `Muse.Prompt.Layer.t()`
    * `:messages`  — provider-ready `Muse.LLM.Message.t()` list
    * `:tools`     — tool spec maps available for this turn

  ## Fields

    * `id`              — unique bundle identifier
    * `session_id`      — session identifier
    * `turn_id`         — turn identifier within the session
    * `muse_id`         — active Muse profile id atom
    * `model`           — model identifier string
    * `layers`          — assembled layers in priority order
    * `messages`        — provider-ready messages
    * `tools`           — available tool specs
    * `response_format` — structured output format
    * `token_estimate`  — total estimated tokens across layers
    * `created_at`      — timestamp
    * `metadata`        — extensible metadata map
  """

  @enforce_keys [:session_id, :muse_id, :layers, :messages, :tools]

  defstruct [
    :id,
    :session_id,
    :turn_id,
    :muse_id,
    :model,
    :layers,
    :messages,
    :tools,
    :response_format,
    :token_estimate,
    :created_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          muse_id: atom(),
          model: String.t() | nil,
          layers: [Muse.Prompt.Layer.t()],
          messages: [Muse.LLM.Message.t()],
          tools: [map()],
          response_format: map() | nil,
          token_estimate: non_neg_integer() | nil,
          created_at: DateTime.t() | nil,
          metadata: map()
        }

  @doc """
  Compute the total token estimate across all layers.
  """
  @spec total_token_estimate(t()) :: non_neg_integer()
  def total_token_estimate(%__MODULE__{layers: layers}) do
    Enum.reduce(layers, 0, fn layer, acc ->
      acc + (layer.token_estimate || Muse.Prompt.Layer.estimate_tokens(layer))
    end)
  end
end
