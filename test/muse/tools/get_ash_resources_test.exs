defmodule Muse.Tools.GetAshResourcesTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.GetAshResources

  describe "execute/2 — basic listing" do
    test "returns domains list and resource count with test injection" do
      test_domains = [
        %{domain: "MyApp.Accounts", resources: ["User", "Account"]},
        %{domain: "MyApp.Blog", resources: ["Post", "Comment"]}
      ]

      result = GetAshResources.execute(%{"muse_test_domains" => test_domains}, %{})

      assert result.success
      assert length(result.output.domains) == 2
      assert result.output.count == 4
    end

    test "returns empty domains when none found via test injection" do
      result = GetAshResources.execute(%{"muse_test_domains" => []}, %{})

      assert result.success
      assert result.output.domains == []
      assert result.output.count == 0
    end

    test "accepts test domains from context metadata" do
      test_domains = [
        %{domain: "MyApp.Inventory", resources: ["Product", "Warehouse", "SKU"]}
      ]

      result = GetAshResources.execute(%{}, %{muse_test_domains: test_domains})

      assert result.success
      assert result.output.count == 3
    end

    test "each domain entry has domain and resources keys" do
      test_domains = [
        %{domain: "MyApp.Accounts", resources: ["User"]}
      ]

      result = GetAshResources.execute(%{"muse_test_domains" => test_domains}, %{})

      assert result.success
      [entry] = result.output.domains
      assert Map.has_key?(entry, :domain)
      assert Map.has_key?(entry, :resources)
    end

    test "handles domain with empty resources gracefully" do
      test_domains = [
        %{domain: "MyApp.Empty", resources: []}
      ]

      result = GetAshResources.execute(%{"muse_test_domains" => test_domains}, %{})

      assert result.success
      assert result.output.count == 0
      assert hd(result.output.domains).resources == []
    end

    test "args injection takes precedence over context" do
      args_domains = [%{domain: "FromArgs", resources: ["A"]}]
      ctx_domains = [%{domain: "FromContext", resources: ["B"]}]

      result =
        GetAshResources.execute(%{"muse_test_domains" => args_domains}, %{
          muse_test_domains: ctx_domains
        })

      assert result.success
      assert hd(result.output.domains).domain == "FromArgs"
    end
  end

  describe "execute/2 — Ash not available" do
    @tag :skip
    test "returns error when Ash is not loaded"
  end

  describe "execute/2 — live discovery" do
    @tag :skip
    test "discovers Ash domains and resources (requires Ash project)"
  end
end
