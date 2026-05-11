defmodule Muse.LLM.CostTrackerTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.CostTracker

  describe "calculate_cost/2" do
    test "returns cost for a known OpenAI model" do
      usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}
      assert CostTracker.calculate_cost("gpt-4o", usage) == 12.5
    end

    test "returns cost for a known Anthropic model" do
      usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}
      assert CostTracker.calculate_cost("claude-3-opus-20240229", usage) == 90.0
    end

    test "returns 0.0 for an unknown model" do
      usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}
      assert CostTracker.calculate_cost("unknown-model", usage) == 0.0
    end

    test "handles string keys in usage map" do
      usage = %{"input_tokens" => 2_000_000, "output_tokens" => 0}
      assert CostTracker.calculate_cost("gpt-4o", usage) == 5.0
    end

    test "returns 0.0 when usage map is empty" do
      assert CostTracker.calculate_cost("gpt-4o", %{}) == 0.0
    end

    test "handles partial usage map" do
      usage = %{input_tokens: 1_000_000}
      assert CostTracker.calculate_cost("gpt-3.5-turbo", usage) == 0.5
    end
  end

  describe "render_cost/1" do
    test "formats small costs with 4 decimals" do
      assert CostTracker.render_cost(0.0042) == "$0.0042"
    end

    test "formats larger costs with 2 decimals" do
      assert CostTracker.render_cost(0.05) == "$0.05"
      assert CostTracker.render_cost(12.5) == "$12.5"
    end

    test "formats zero cost" do
      assert CostTracker.render_cost(0.0) == "$0.0"
    end
  end

  describe "known_model?/1" do
    test "returns true for a known model" do
      assert CostTracker.known_model?("gpt-4o")
    end

    test "returns false for an unknown model" do
      refute CostTracker.known_model?("unknown")
    end
  end
end
