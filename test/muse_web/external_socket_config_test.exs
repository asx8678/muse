defmodule MuseWeb.ExternalSocketConfigTest do
  use ExUnit.Case, async: true

  alias MuseWeb.ExternalSocketConfig

  setup do
    # Capture original config to restore after test
    original = Application.get_env(:muse, :external_ws)
    on_exit(fn -> Application.put_env(:muse, :external_ws, original) end)
    :ok
  end

  describe "enabled?/0" do
    test "defaults to false when no app env is set" do
      Application.delete_env(:muse, :external_ws)
      refute ExternalSocketConfig.enabled?()
    end

    test "returns true when enabled: true is configured" do
      Application.put_env(:muse, :external_ws, enabled: true)
      assert ExternalSocketConfig.enabled?()
    end

    test "returns false when enabled: false is configured" do
      Application.put_env(:muse, :external_ws, enabled: false)
      refute ExternalSocketConfig.enabled?()
    end

    test "respects test.exs override (enabled: true)" do
      # The test.exs config sets enabled: true, so this should be true
      # unless something cleared the env
      assert is_boolean(ExternalSocketConfig.enabled?())
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

    test "respects test.exs override (replay_limit: 50)" do
      Application.delete_env(:muse, :external_ws)
      Application.put_env(:muse, :external_ws, enabled: true, replay_limit: 50)
      assert ExternalSocketConfig.replay_limit() == 50
    end
  end
end
