defmodule MuseWeb.ExternalSocketConfigTest do
  use ExUnit.Case, async: false

  alias MuseWeb.ExternalSocketConfig

  setup do
    original_env = Application.get_env(:muse, :external_ws)
    original_sys = System.get_env("MUSE_EXTERNAL_WS")

    on_exit(fn ->
      if original_env do
        Application.put_env(:muse, :external_ws, original_env)
      else
        Application.delete_env(:muse, :external_ws)
      end

      if original_sys do
        System.put_env("MUSE_EXTERNAL_WS", original_sys)
      else
        System.delete_env("MUSE_EXTERNAL_WS")
      end
    end)

    :ok
  end

  describe "enabled?/0" do
    test "defaults to false when no app env or env var is set" do
      Application.delete_env(:muse, :external_ws)
      System.delete_env("MUSE_EXTERNAL_WS")
      refute ExternalSocketConfig.enabled?()
    end

    test "returns true when enabled: true is configured" do
      System.delete_env("MUSE_EXTERNAL_WS")
      Application.put_env(:muse, :external_ws, enabled: true)
      assert ExternalSocketConfig.enabled?()
    end

    test "returns true when MUSE_EXTERNAL_WS=true even if app config is false" do
      System.put_env("MUSE_EXTERNAL_WS", "true")
      Application.put_env(:muse, :external_ws, enabled: false)
      # Env var wins — enabled: false does not mask runtime opt-in
      assert ExternalSocketConfig.enabled?()
    end
  end

  describe "enabled?/0 — MUSE_EXTERNAL_WS env var" do
    test "returns true when MUSE_EXTERNAL_WS=true" do
      Application.delete_env(:muse, :external_ws)
      System.put_env("MUSE_EXTERNAL_WS", "true")
      assert ExternalSocketConfig.enabled?()
    end

    test "returns true when MUSE_EXTERNAL_WS=1" do
      Application.delete_env(:muse, :external_ws)
      System.put_env("MUSE_EXTERNAL_WS", "1")
      assert ExternalSocketConfig.enabled?()
    end

    test "returns true when MUSE_EXTERNAL_WS=yes" do
      Application.delete_env(:muse, :external_ws)
      System.put_env("MUSE_EXTERNAL_WS", "yes")
      assert ExternalSocketConfig.enabled?()
    end

    test "returns true when MUSE_EXTERNAL_WS=on" do
      Application.delete_env(:muse, :external_ws)
      System.put_env("MUSE_EXTERNAL_WS", "on")
      assert ExternalSocketConfig.enabled?()
    end

    test "returns false when MUSE_EXTERNAL_WS is set to other values" do
      Application.delete_env(:muse, :external_ws)

      for value <- ["false", "0", "no", "off", "TRUE", "Yes", "ON", "", "random"] do
        System.put_env("MUSE_EXTERNAL_WS", value)

        refute ExternalSocketConfig.enabled?(),
               "Expected false for MUSE_EXTERNAL_WS=#{inspect(value)}"
      end
    end

    test "returns false when MUSE_EXTERNAL_WS is not set" do
      Application.delete_env(:muse, :external_ws)
      System.delete_env("MUSE_EXTERNAL_WS")
      refute ExternalSocketConfig.enabled?()
    end

    test "app config true overrides env var not set" do
      System.delete_env("MUSE_EXTERNAL_WS")
      Application.put_env(:muse, :external_ws, enabled: true)
      assert ExternalSocketConfig.enabled?()
    end

    test "env var truthy values enable the socket regardless of app config false" do
      System.put_env("MUSE_EXTERNAL_WS", "true")
      Application.put_env(:muse, :external_ws, enabled: false)
      assert ExternalSocketConfig.enabled?()
    end
  end

  describe "replay_limit/0" do
    test "defaults to 100 when no app env is set" do
      Application.delete_env(:muse, :external_ws)
      assert ExternalSocketConfig.replay_limit() == 100
    end

    test "returns configured value" do
      Application.put_env(:muse, :external_ws, replay_limit: 200)
      assert ExternalSocketConfig.replay_limit() == 200
    end

    test "returns 0 when configured to 0" do
      Application.put_env(:muse, :external_ws, replay_limit: 0)
      assert ExternalSocketConfig.replay_limit() == 0
    end

    test "parses non-negative string values" do
      Application.put_env(:muse, :external_ws, replay_limit: "25")
      assert ExternalSocketConfig.replay_limit() == 25
    end

    test "falls back to default for invalid values" do
      for invalid <- [-1, "-1", "not-an-integer", nil, :bad] do
        Application.put_env(:muse, :external_ws, replay_limit: invalid)

        assert ExternalSocketConfig.replay_limit() == 100,
               "Expected default replay limit for #{inspect(invalid)}"
      end
    end
  end
end
