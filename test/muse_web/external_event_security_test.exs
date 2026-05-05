defmodule MuseWeb.ExternalEventSecurityTest do
  use ExUnit.Case, async: true

  alias Muse.Event
  alias MuseWeb.ExternalEventFilter

  @timestamp ~U[2025-01-01 00:00:00Z]

  defp event(attrs) do
    source = Keyword.get(attrs, :source, :web)
    type = Keyword.get(attrs, :type, :user_message)
    data = Keyword.get(attrs, :data, %{text: "hello"})

    opts =
      [
        id: Keyword.get(attrs, :id, 101),
        timestamp: Keyword.get(attrs, :timestamp, @timestamp),
        session_id: Keyword.get(attrs, :session_id, "session-123"),
        turn_id: Keyword.get(attrs, :turn_id),
        seq: Keyword.get(attrs, :seq),
        parent_id: Keyword.get(attrs, :parent_id),
        visibility: Keyword.get(attrs, :visibility, :user),
        muse_id: Keyword.get(attrs, :muse_id)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Event.new(source, type, data, opts)
  end

  defp external_json!(event, opts \\ []) do
    assert {:ok, json} = ExternalEventFilter.to_external_json(event, opts)
    json
  end

  describe "visibility boundary" do
    test "forwards only explicit user-visible events by default" do
      assert {:ok, map} =
               event(visibility: :user)
               |> ExternalEventFilter.to_external_map()

      assert map["visibility"] == "user"
      assert map["payload"]["text"] == "hello"
    end

    test "denies internal, sensitive, and debug visibility" do
      for visibility <- [:internal, :sensitive, :debug] do
        assert {:error, {:denied_visibility, ^visibility}} =
                 event(visibility: visibility)
                 |> ExternalEventFilter.to_external_map()
      end
    end

    test "denies nil visibility unless the type is on the safe allowlist" do
      nil_visibility_event = event(source: :web, type: :simulated, visibility: nil)

      assert {:error, :nil_visibility_type_not_allowed} =
               ExternalEventFilter.to_external_map(nil_visibility_event, [])
    end

    test "nil visibility allowlisted type is allowed for non-provider sources" do
      allowlisted = event(source: :web, type: :user_message, visibility: nil)

      assert {:ok, map} = ExternalEventFilter.to_external_map(allowlisted, [])
      assert map["type"] == "user_message"
    end

    test "nil visibility allowlisted type is still denied for provider/auth/debug sources" do
      provider_debug =
        event(
          source: :openai_provider_debug,
          type: :assistant_delta,
          data: %{body: "Authorization: Bearer raw-provider-secret"},
          visibility: nil
        )

      assert {:error, :provider_auth_debug_denied} =
               ExternalEventFilter.to_external_map(provider_debug, [])
    end

    test "filter drops denied events instead of forwarding them" do
      forwarded =
        [
          event(id: 1, visibility: :user),
          event(id: 2, visibility: :internal),
          event(id: 3, visibility: :sensitive),
          event(id: 4, visibility: nil, type: :unknown)
        ]
        |> ExternalEventFilter.filter([])

      assert Enum.map(forwarded, & &1["id"]) == [1]
    end
  end

  describe "redaction before JSON" do
    test "removes API keys, bearer tokens, authorization headers, and OAuth/Codex tokens" do
      event =
        event(
          data: %{
            api_key: "sk-live-secret-123456",
            headers: %{
              "Authorization" => "Bearer header-token-secret",
              "X-Api-Key" => "key-live-secret-abcdef"
            },
            text: """
            curl -H 'Authorization: Bearer bearer-token-secret' \
              'https://api.example.test?oauth_token=ya29.oauth-token-secret&safe=1'
            codex_auth_token=codex-token-secret
            github=gho_abcdefghijklmnopqrstuvwxyz123456
            key=key-live-secret-abcdef
            jwt=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJtdXNlIn0.signatureSecret
            """
          }
        )

      json = external_json!(event)

      assert json =~ "[REDACTED]"
      refute json =~ "sk-live-secret"
      refute json =~ "bearer-token-secret"
      refute json =~ "header-token-secret"
      refute json =~ "Authorization: Bearer"
      refute json =~ "oauth-token-secret"
      refute json =~ "ya29."
      refute json =~ "codex-token-secret"
      refute json =~ "gho_abcdefghijklmnopqrstuvwxyz123456"
      refute json =~ "key-live-secret-abcdef"
      refute json =~ "signatureSecret"
    end

    test "provider/auth debug with :user visibility is forwarded but remains redacted" do
      provider_user_event =
        event(
          source: :auth_provider,
          type: :raw_response_debug,
          visibility: :user,
          data: %{body: "Authorization: Bearer auth-debug-secret"}
        )

      assert {:ok, json} = ExternalEventFilter.to_external_json(provider_user_event, [])
      assert json =~ "[REDACTED]"
      refute json =~ "auth-debug-secret"
    end
  end

  describe "plan payload and internal struct suppression" do
    test "omits raw structured plan JSON through EventDisplay rules" do
      raw_plan_json =
        ~s({"objective":"Do not leak this raw objective","tasks":[{"title":"Secret task"}]})

      json =
        event(data: %{text: raw_plan_json, nested: %{plan_json: raw_plan_json}})
        |> external_json!()

      assert json =~ "structured plan JSON omitted"
      refute json =~ "Do not leak this raw objective"
      refute json =~ "Secret task"
    end

    test "omits arbitrary structs rather than inspecting sensitive internals" do
      uri_with_userinfo = %URI{
        scheme: "https",
        userinfo: "user:super-secret-password",
        host: "example.test",
        path: "/resource"
      }

      assert {:ok, map} =
               event(data: %{uri: uri_with_userinfo})
               |> ExternalEventFilter.to_external_map([])

      assert map["payload"]["uri"] == "[struct omitted]"

      json = Jason.encode!(map)
      refute json =~ "super-secret-password"
      refute json =~ "userinfo"
    end
  end

  describe "session id boundary" do
    test "rejects invalid session ids instead of treating them as paths" do
      for invalid <- ["", ".", "..", "../escape", "sub/../escape", "foo\\bar", "foo\0bar"] do
        assert {:error, {:invalid_session_id, ^invalid}} =
                 event(session_id: invalid)
                 |> ExternalEventFilter.to_external_map([])
      end
    end

    test "valid_session_id?/1 rejects nil, path-like/non-binary ids, and too-long values" do
      refute ExternalEventFilter.valid_session_id?(nil)
      assert ExternalEventFilter.valid_session_id?("session-123_ok")

      refute ExternalEventFilter.valid_session_id?("../escape")
      refute ExternalEventFilter.valid_session_id?("foo/bar")
      refute ExternalEventFilter.valid_session_id?("foo\\bar")
      refute ExternalEventFilter.valid_session_id?("foo\0bar")
      refute ExternalEventFilter.valid_session_id?(:atom_session)
      refute ExternalEventFilter.valid_session_id?(String.duplicate("a", 257))
    end
  end
end
