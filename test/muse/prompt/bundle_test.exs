defmodule Muse.Prompt.BundleTest do
  use ExUnit.Case, async: true

  alias Muse.Prompt.{Bundle, Layer}

  describe "struct enforcement" do
    test "requires enforced keys: session_id, muse_id, layers, messages, tools" do
      assert_raise ArgumentError, fn ->
        struct!(Bundle, muse_id: :planning, layers: [], messages: [], tools: [])
      end
    end

    test "creates bundle when all enforced keys present" do
      bundle = %Bundle{
        session_id: "sess_1",
        muse_id: :planning,
        layers: [],
        messages: [],
        tools: []
      }

      assert bundle.session_id == "sess_1"
      assert bundle.muse_id == :planning
    end
  end

  describe "default field values" do
    test "metadata defaults to empty map" do
      bundle = %Bundle{session_id: "s", muse_id: :planning, layers: [], messages: [], tools: []}
      assert bundle.metadata == %{}
    end

    test "optional fields default to nil" do
      bundle = %Bundle{session_id: "s", muse_id: :planning, layers: [], messages: [], tools: []}

      assert bundle.id == nil
      assert bundle.turn_id == nil
      assert bundle.model == nil
      assert bundle.response_format == nil
      assert bundle.token_estimate == nil
      assert bundle.created_at == nil
    end
  end

  describe "total_token_estimate/1" do
    test "sums token estimates across all layers" do
      layers = [
        Layer.new!(id: :a, priority: 1, source: :system, content: String.duplicate("A", 40)),
        Layer.new!(id: :b, priority: 2, source: :system, content: String.duplicate("B", 80))
      ]

      bundle = %Bundle{
        session_id: "s",
        muse_id: :planning,
        layers: Enum.map(layers, &Layer.with_token_estimate/1),
        messages: [],
        tools: []
      }

      # 40/4 + 80/4 = 10 + 20 = 30
      assert Bundle.total_token_estimate(bundle) == 30
    end

    test "uses estimate_tokens when token_estimate is nil" do
      layers = [
        Layer.new!(id: :a, priority: 1, source: :system, content: String.duplicate("A", 40))
      ]

      bundle = %Bundle{
        session_id: "s",
        muse_id: :planning,
        layers: layers,
        messages: [],
        tools: []
      }

      assert Bundle.total_token_estimate(bundle) == 10
    end

    test "returns 0 for empty layers" do
      bundle = %Bundle{session_id: "s", muse_id: :planning, layers: [], messages: [], tools: []}
      assert Bundle.total_token_estimate(bundle) == 0
    end
  end
end
