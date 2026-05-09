defmodule Muse.EnvTest do
  use ExUnit.Case, async: false

  alias Muse.Env

  # -- Helpers ------------------------------------------------------------------

  defp with_app_env(key, value, fun) do
    original = Application.get_env(:muse, key)
    Application.put_env(:muse, key, value)

    try do
      fun.()
    after
      if is_nil(original) do
        Application.delete_env(:muse, key)
      else
        Application.put_env(:muse, key, original)
      end
    end
  end

  # -- dev_tools_enabled? -------------------------------------------------------

  describe "dev_tools_enabled?/0" do
    test "returns false by default (production-safe)" do
      # Ensure the key is not set so we test the default
      with_app_env(:dev_tools_enabled, nil, fn ->
        Application.delete_env(:muse, :dev_tools_enabled)
        assert Env.dev_tools_enabled?() == false
      end)
    end

    test "returns true when explicitly set to true" do
      with_app_env(:dev_tools_enabled, true, fn ->
        assert Env.dev_tools_enabled?() == true
      end)
    end

    test "returns false when explicitly set to false" do
      with_app_env(:dev_tools_enabled, false, fn ->
        assert Env.dev_tools_enabled?() == false
      end)
    end

    test "returns false for truthy non-boolean values" do
      with_app_env(:dev_tools_enabled, "yes", fn ->
        assert Env.dev_tools_enabled?() == false
      end)
    end
  end

  # -- runtime_provider_enabled? -----------------------------------------------

  describe "runtime_provider_enabled?/0" do
    test "returns true by default (historical dev/prod behavior)" do
      with_app_env(:runtime_provider_enabled, nil, fn ->
        Application.delete_env(:muse, :runtime_provider_enabled)
        assert Env.runtime_provider_enabled?() == true
      end)
    end

    test "returns true when explicitly set to true" do
      with_app_env(:runtime_provider_enabled, true, fn ->
        assert Env.runtime_provider_enabled?() == true
      end)
    end

    test "returns false when explicitly set to false" do
      with_app_env(:runtime_provider_enabled, false, fn ->
        assert Env.runtime_provider_enabled?() == false
      end)
    end

    test "returns false for truthy non-boolean values" do
      with_app_env(:runtime_provider_enabled, 1, fn ->
        assert Env.runtime_provider_enabled?() == false
      end)
    end
  end
end
