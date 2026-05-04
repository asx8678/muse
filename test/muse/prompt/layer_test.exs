defmodule Muse.Prompt.LayerTest do
  use ExUnit.Case, async: true

  alias Muse.Prompt.Layer

  describe "struct enforcement" do
    test "requires enforced keys: id, priority, source, content" do
      assert_raise ArgumentError, fn ->
        Layer.new!(priority: 1, source: :system, content: "x")
      end

      assert_raise ArgumentError, fn ->
        Layer.new!(id: :test, source: :system, content: "x")
      end

      assert_raise ArgumentError, fn ->
        Layer.new!(id: :test, priority: 1, content: "x")
      end

      assert_raise ArgumentError, fn ->
        Layer.new!(id: :test, priority: 1, source: :system)
      end
    end

    test "creates layer when all enforced keys present" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "Be safe.")

      assert %Layer{} = layer
      assert layer.id == :test
      assert layer.priority == 1
      assert layer.source == :system
      assert layer.content == "Be safe."
    end

    test "accepts keyword list input" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "x")
      assert layer.id == :test
    end

    test "accepts map input" do
      layer = Layer.new!(%{id: :test, priority: 1, source: :system, content: "x"})
      assert layer.id == :test
    end
  end

  describe "default field values" do
    test "visibility defaults to :internal" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "x")
      assert layer.visibility == :internal
    end

    test "kind defaults to :instruction" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "x")
      assert layer.kind == :instruction
    end

    test "token_estimate defaults to nil" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "x")
      assert layer.token_estimate == nil
    end

    test "redaction defaults to :standard" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "x")
      assert layer.redaction == :standard
    end

    test "metadata defaults to empty map" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "x")
      assert layer.metadata == %{}
    end

    test "title defaults to nil" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "x")
      assert layer.title == nil
    end
  end

  describe "optional fields" do
    test "all optional fields can be set" do
      layer =
        Layer.new!(
          id: :test,
          priority: 5,
          source: :project,
          content: "project rules",
          title: "Project Rules",
          visibility: :user_visible,
          kind: :context,
          token_estimate: 42,
          redaction: :none,
          metadata: %{files: 3}
        )

      assert layer.title == "Project Rules"
      assert layer.visibility == :user_visible
      assert layer.kind == :context
      assert layer.token_estimate == 42
      assert layer.redaction == :none
      assert layer.metadata == %{files: 3}
    end
  end

  describe "estimate_tokens/1" do
    test "estimates tokens using 4 chars per token heuristic" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "AABB")
      # 4 bytes = 1 token
      assert Layer.estimate_tokens(layer) == 1
    end

    test "handles nil content" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "x")
      layer = %{layer | content: nil}
      assert Layer.estimate_tokens(layer) == 0
    end

    test "handles longer content" do
      content = String.duplicate("A", 400)
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: content)
      assert Layer.estimate_tokens(layer) == 100
    end
  end

  describe "with_token_estimate/1" do
    test "populates token_estimate when nil" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "AAAA")
      refute layer.token_estimate
      estimated = Layer.with_token_estimate(layer)
      assert estimated.token_estimate == 1
    end

    test "preserves existing token_estimate" do
      layer =
        Layer.new!(id: :test, priority: 1, source: :system, content: "AAAA", token_estimate: 42)

      estimated = Layer.with_token_estimate(layer)
      assert estimated.token_estimate == 42
    end
  end

  describe "no dynamic atom creation" do
    test "source values are compile-time atoms only" do
      layer = Layer.new!(id: :test, priority: 1, source: :system, content: "x")
      assert layer.source in [:system, :muse_profile, :project, :user]
    end
  end
end
