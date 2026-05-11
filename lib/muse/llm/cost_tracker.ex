defmodule Muse.LLM.CostTracker do
  @moduledoc """
  Cost estimation for LLM calls based on token usage and provider pricing.

  Pricing data is approximate and subject to change. Unknown models return
  $0.00 so that missing pricing never crashes the caller.
  """

  # Prices are per 1M tokens (USD). Approximate — varies by provider and date.
  @pricing %{
    # OpenAI
    "gpt-4o" => %{input: 2.50, output: 10.00},
    "gpt-4o-mini" => %{input: 0.15, output: 0.60},
    "gpt-4-turbo" => %{input: 10.00, output: 30.00},
    "gpt-4" => %{input: 30.00, output: 60.00},
    "gpt-3.5-turbo" => %{input: 0.50, output: 1.50},
    "o1" => %{input: 15.00, output: 60.00},
    "o1-mini" => %{input: 3.00, output: 12.00},
    "o3-mini" => %{input: 1.10, output: 4.40},
    # Anthropic
    "claude-sonnet-4-20250514" => %{input: 3.00, output: 15.00},
    "claude-3.7-sonnet-20250219" => %{input: 3.00, output: 15.00},
    "claude-3.5-sonnet-20241022" => %{input: 3.00, output: 15.00},
    "claude-3.5-haiku-20241022" => %{input: 0.80, output: 4.00},
    "claude-3-opus-20240229" => %{input: 15.00, output: 75.00},
    # OpenRouter (approximate — varies by provider)
    "anthropic/claude-sonnet-4-20250514" => %{input: 3.00, output: 15.00},
    "anthropic/claude-3.5-sonnet" => %{input: 3.00, output: 15.00},
    "openai/gpt-4o" => %{input: 2.50, output: 10.00},
    "openai/gpt-4o-mini" => %{input: 0.15, output: 0.60},
    "google/gemini-2.0-flash-001" => %{input: 0.10, output: 0.40},
    "meta-llama/llama-3.1-70b-instruct" => %{input: 0.59, output: 0.79}
  }

  @doc """
  Calculate the estimated USD cost for a given model and token usage.

  `usage` is a map with `:input_tokens` and `:output_tokens` (or string
  equivalents). Missing or nil values default to 0.
  """
  @spec calculate_cost(String.t(), map()) :: float()
  def calculate_cost(model_id, usage) when is_binary(model_id) and is_map(usage) do
    pricing = Map.get(@pricing, model_id, %{input: 0, output: 0})

    input_tokens =
      Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0

    output_tokens =
      Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0

    input_cost = input_tokens / 1_000_000 * pricing.input
    output_cost = output_tokens / 1_000_000 * pricing.output
    Float.round(input_cost + output_cost, 6)
  end

  def calculate_cost(_model_id, _usage), do: 0.0

  @doc """
  Format a cost float as a human-readable string.
  """
  @spec render_cost(float()) :: String.t()
  def render_cost(cost) when is_float(cost) do
    if cost < 0.01 do
      "$#{Float.round(cost, 4)}"
    else
      "$#{Float.round(cost, 2)}"
    end
  end

  def render_cost(cost) when is_integer(cost), do: render_cost(cost * 1.0)
  def render_cost(_), do: "$0.0"

  @doc """
  Return true if the model ID exists in the pricing catalog.
  """
  @spec known_model?(String.t()) :: boolean()
  def known_model?(model_id) when is_binary(model_id), do: Map.has_key?(@pricing, model_id)
  def known_model?(_), do: false

  @doc """
  Return the pricing map for a model, or nil if unknown.
  """
  @spec pricing_for(String.t()) :: %{input: float(), output: float()} | nil
  def pricing_for(model_id) when is_binary(model_id), do: Map.get(@pricing, model_id)
  def pricing_for(_), do: nil
end
