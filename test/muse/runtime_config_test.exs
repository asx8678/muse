defmodule Muse.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @valid_secret String.duplicate("a", 64)

  setup do
    original = System.get_env("MUSE_SECRET_KEY_BASE")

    on_exit(fn -> restore_env("MUSE_SECRET_KEY_BASE", original) end)

    :ok
  end

  test "does not require MUSE_SECRET_KEY_BASE outside prod" do
    System.delete_env("MUSE_SECRET_KEY_BASE")

    assert Config.Reader.read!(@runtime_config, env: :test) == []
  end

  test "requires MUSE_SECRET_KEY_BASE in prod" do
    System.delete_env("MUSE_SECRET_KEY_BASE")

    assert_raise RuntimeError, ~r/MUSE_SECRET_KEY_BASE is missing/, fn ->
      Config.Reader.read!(@runtime_config, env: :prod)
    end
  end

  test "rejects short MUSE_SECRET_KEY_BASE values in prod" do
    System.put_env("MUSE_SECRET_KEY_BASE", "short")

    assert_raise RuntimeError, ~r/must be at least 64 bytes/, fn ->
      Config.Reader.read!(@runtime_config, env: :prod)
    end
  end

  test "configures prod endpoint secret_key_base from MUSE_SECRET_KEY_BASE" do
    System.put_env("MUSE_SECRET_KEY_BASE", @valid_secret)

    config = Config.Reader.read!(@runtime_config, env: :prod)

    endpoint_config =
      config
      |> Keyword.fetch!(:muse)
      |> Keyword.fetch!(MuseWeb.Endpoint)

    assert Keyword.fetch!(endpoint_config, :secret_key_base) == @valid_secret
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
