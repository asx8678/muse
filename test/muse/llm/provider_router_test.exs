defmodule Muse.LLM.ProviderRouterTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.{FakeProvider, OpenAICompatibleProvider, ProviderConfig, ProviderRouter}

  describe "resolve/1" do
    test "maps fake atom and string identifiers to FakeProvider" do
      assert ProviderRouter.resolve(:fake) == {:ok, FakeProvider}
      assert ProviderRouter.resolve("fake") == {:ok, FakeProvider}
    end

    test "maps fake ProviderConfig to FakeProvider" do
      assert ProviderRouter.resolve(ProviderConfig.fake()) == {:ok, FakeProvider}
      assert ProviderRouter.resolve(%ProviderConfig{id: :fake}) == {:ok, FakeProvider}
    end

    test "maps OpenAI-compatible atom and string identifiers" do
      assert ProviderRouter.resolve(:openai_compatible) == {:ok, OpenAICompatibleProvider}
      assert ProviderRouter.resolve("openai_compatible") == {:ok, OpenAICompatibleProvider}
    end

    test "maps OpenAI-compatible ProviderConfig by id" do
      config = %ProviderConfig{id: "openai_compatible"}

      assert ProviderRouter.resolve(config) == {:ok, OpenAICompatibleProvider}
    end

    test "returns explicit errors for unknown providers" do
      assert ProviderRouter.resolve(:anthropic) == {:error, {:unknown_provider, :anthropic}}
      assert ProviderRouter.resolve("anthropic") == {:error, {:unknown_provider, "anthropic"}}
      assert ProviderRouter.resolve(nil) == {:error, {:unknown_provider, nil}}
    end

    test "returns only the provider config id for unknown ProviderConfig input" do
      config = %ProviderConfig{
        id: "custom-secret-provider",
        headers: %{"Authorization" => "Bearer should-not-leak"}
      }

      assert ProviderRouter.resolve(config) ==
               {:error, {:unknown_provider, "custom-secret-provider"}}
    end

    test "does not create atoms from unknown strings" do
      unknown = "unknown_provider_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
      assert ProviderRouter.resolve(unknown) == {:error, {:unknown_provider, unknown}}
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end

  describe "resolve!/1" do
    test "returns the module for known providers" do
      assert ProviderRouter.resolve!(:fake) == FakeProvider
    end

    test "raises for unknown providers" do
      assert_raise ArgumentError, ~r/unknown LLM provider: "missing"/, fn ->
        ProviderRouter.resolve!("missing")
      end
    end
  end
end
