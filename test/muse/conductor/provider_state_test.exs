defmodule Muse.Conductor.ProviderStateTest do
  use ExUnit.Case, async: true

  alias Muse.Conductor
  alias Muse.{Session}
  alias Muse.LLM.Response

  describe "merge_provider_state/2" do
    test "merges previous_response_id into session" do
      session = Session.new(workspace: "/tmp")
      response = Response.new(provider_state: %{previous_response_id: "resp_new"})

      updated = Conductor.merge_provider_state(session, response)

      assert updated.provider_state == %{previous_response_id: "resp_new"}
    end

    test "preserves existing provider_state keys" do
      session = Session.new(workspace: "/tmp", provider_state: %{existing_key: "value"})
      response = Response.new(provider_state: %{previous_response_id: "resp_new"})

      updated = Conductor.merge_provider_state(session, response)

      assert updated.provider_state[:previous_response_id] == "resp_new"
      assert updated.provider_state[:existing_key] == "value"
    end

    test "filters out sensitive keys" do
      session = Session.new(workspace: "/tmp")

      response =
        Response.new(provider_state: %{previous_response_id: "resp_new", api_key: "secret_value"})

      updated = Conductor.merge_provider_state(session, response)

      assert updated.provider_state[:previous_response_id] == "resp_new"
      refute updated.provider_state[:api_key]
    end

    test "handles nil provider_state in response" do
      session = Session.new(workspace: "/tmp", provider_state: %{existing: "data"})
      response = Response.new(provider_state: nil)

      updated = Conductor.merge_provider_state(session, response)

      assert updated.provider_state == %{existing: "data"}
    end

    test "handles nil provider_state in session" do
      session = Session.new(workspace: "/tmp")
      response = Response.new(provider_state: %{previous_response_id: "resp_1"})

      updated = Conductor.merge_provider_state(session, response)

      assert updated.provider_state == %{previous_response_id: "resp_1"}
    end

    test "redacts values of sensitive keys even if whitelisted" do
      # Belt-and-suspenders: if a key happens to be both safe and sensitive
      session = Session.new(workspace: "/tmp")

      response =
        Response.new(
          provider_state: %{previous_response_id: "resp_safe", password: "super_secret"}
        )

      updated = Conductor.merge_provider_state(session, response)

      # password is not in the safe keys list, so it's filtered out
      refute updated.provider_state[:password]
      assert updated.provider_state[:previous_response_id] == "resp_safe"
    end
  end
end
