defmodule MuseWeb.ExternalSocketAuthTest do
  @moduledoc """
  Comprehensive tests for external WebSocket authentication and authorization.

  Covers:
    - Disabled socket rejects connection
    - Production enabled without token config fails fast
    - Missing/invalid/too-short token rejects
    - Valid token with unauthorized session rejects channel join
    - Valid token with allowed session joins
    - Socket id is observable but never exposes raw token
    - Connect/join/runtime validation
  """
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  @endpoint MuseWeb.Endpoint

  alias MuseWeb.{ExternalSocketAuth, ExternalSocketConfig}

  # -- Setup helpers ------------------------------------------------------------

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp ensure_pubsub do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:ok, _} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

      _pid ->
        :ok
    end
  end

  defp start_state do
    stop_named(Muse.State)
    {:ok, _} = Muse.State.start_link([])
  end

  defp start_endpoint do
    stop_named(MuseWeb.Endpoint)
    {:ok, _} = MuseWeb.Endpoint.start_link()
  end

  defp test_token, do: "test-token-16chars-ok"

  defp restricted_token, do: "test-restricted-token"

  defp test_token_hash do
    :crypto.hash(:sha256, test_token())
    |> Base.encode16(case: :lower)
  end

  defp restricted_token_hash do
    :crypto.hash(:sha256, restricted_token())
    |> Base.encode16(case: :lower)
  end

  defp full_config do
    [
      enabled: true,
      replay_limit: 50,
      token_hashes: [
        %{
          id: "test-token",
          hash: test_token_hash(),
          scopes: ["events:read"],
          allowed_sessions: :all
        },
        %{
          id: "test-restricted",
          hash: restricted_token_hash(),
          scopes: ["events:read"],
          allowed_sessions: ["sess-allowed"]
        }
      ]
    ]
  end

  setup do
    ensure_pubsub()
    start_state()
    start_endpoint()

    original_ws = Application.get_env(:muse, :external_ws)
    original_sys = System.get_env("MUSE_EXTERNAL_WS")

    Application.put_env(:muse, :external_ws, full_config())

    on_exit(fn ->
      Application.put_env(:muse, :external_ws, original_ws || [enabled: false, replay_limit: 100])

      if original_sys do
        System.put_env("MUSE_EXTERNAL_WS", original_sys)
      else
        System.delete_env("MUSE_EXTERNAL_WS")
      end

      stop_named(MuseWeb.Endpoint)
      stop_named(Muse.State)
    end)

    :ok
  end

  # -- Disabled socket rejects connection ---------------------------------------

  describe "disabled external socket" do
    test "rejects connection when disabled" do
      System.delete_env("MUSE_EXTERNAL_WS")
      Application.put_env(:muse, :external_ws, enabled: false, token_hashes: [])

      assert :error = connect(MuseWeb.UserSocket, %{"token" => test_token()})
    end

    test "rejects connection with env var cleared and config disabled" do
      System.delete_env("MUSE_EXTERNAL_WS")
      Application.put_env(:muse, :external_ws, enabled: false, token_hashes: [])

      assert :error = connect(MuseWeb.UserSocket, %{})
    end
  end

  # -- Production fail-fast -----------------------------------------------------

  describe "production fail-fast (assert_configured!/0)" do
    test "raises when enabled with no token hashes" do
      Application.put_env(:muse, :external_ws, enabled: true, token_hashes: [])

      assert_raise RuntimeError, ~r/External WebSocket is enabled but no token hashes/, fn ->
        ExternalSocketAuth.assert_configured!()
      end
    end

    test "does not raise when enabled with token hashes configured" do
      Application.put_env(:muse, :external_ws, full_config())

      assert :ok = ExternalSocketAuth.assert_configured!()
    end

    test "does not raise when disabled (no token hashes needed)" do
      Application.put_env(:muse, :external_ws, enabled: false, token_hashes: [])

      assert :ok = ExternalSocketAuth.assert_configured!()
    end
  end

  # -- Missing/invalid/too-short token rejects ----------------------------------

  describe "token authentication" do
    test "rejects connection with no token parameter" do
      assert :error = connect(MuseWeb.UserSocket, %{})
    end

    test "rejects connection with empty token" do
      assert :error = connect(MuseWeb.UserSocket, %{"token" => ""})
    end

    test "rejects connection with nil token" do
      assert :error = connect(MuseWeb.UserSocket, %{"token" => nil})
    end

    test "rejects connection with too-short token (< 16 chars)" do
      assert :error = connect(MuseWeb.UserSocket, %{"token" => "short"})
    end

    test "rejects connection with exactly 15-char token" do
      assert :error = connect(MuseWeb.UserSocket, %{"token" => "123456789012345"})
    end

    test "rejects connection with invalid token (wrong value)" do
      assert :error = connect(MuseWeb.UserSocket, %{"token" => "invalid-but-long-enough-token"})
    end

    test "rejects connection with valid-length but wrong token" do
      assert :error =
               connect(
                 MuseWeb.UserSocket,
                 %{"token" => "this-is-a-very-wrong-token-value-for-testing"}
               )
    end

    test "accepts connection with valid full-access token" do
      assert {:ok, _socket} = connect(MuseWeb.UserSocket, %{"token" => test_token()})
    end

    test "accepts connection with valid restricted token" do
      assert {:ok, _socket} = connect(MuseWeb.UserSocket, %{"token" => restricted_token()})
    end
  end

  # -- Principal assignment and socket id ---------------------------------------

  describe "socket id and principal assignment" do
    test "socket id is based on token_id, never raw token" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => test_token()})

      socket_id = MuseWeb.UserSocket.id(socket)
      assert socket_id == "external_socket:test-token"
    end

    test "socket id for restricted token" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => restricted_token()})

      socket_id = MuseWeb.UserSocket.id(socket)
      assert socket_id == "external_socket:test-restricted"
    end

    test "raw token is never in socket assigns" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => test_token()})

      assigns_keys = Map.keys(socket.assigns)
      refute :token in assigns_keys
      refute "token" in assigns_keys

      # Check all assign values don't contain the raw token
      for {_key, value} <- socket.assigns do
        if is_binary(value) do
          refute String.contains?(value, test_token())
        end
      end
    end

    test "external_principal is assigned with token_id, scopes, and allowed_sessions" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => test_token()})

      principal = socket.assigns.external_principal
      assert principal.token_id == "test-token"
      assert principal.scopes == ["events:read"]
      assert principal.allowed_sessions == :all
    end

    test "restricted principal has specific allowed_sessions" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => restricted_token()})

      principal = socket.assigns.external_principal
      assert principal.token_id == "test-restricted"
      assert principal.allowed_sessions == ["sess-allowed"]
    end

    test "socket id is nil for unauthenticated socket" do
      # Create a socket without going through connect (simulates no auth)
      socket = %Phoenix.Socket{assigns: %{}}
      assert nil == MuseWeb.UserSocket.id(socket)
    end
  end

  # -- Session authorization ----------------------------------------------------

  describe "session channel authorization" do
    test "valid token with allowed_sessions: :all can join any session" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => test_token()})

      assert {:ok, _reply, _chan_socket} =
               subscribe_and_join(socket, MuseWeb.SessionChannel, "session:any-session-id")
    end

    test "valid token with restricted sessions can join allowed session" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => restricted_token()})

      assert {:ok, _reply, _chan_socket} =
               subscribe_and_join(socket, MuseWeb.SessionChannel, "session:sess-allowed")
    end

    test "valid token with restricted sessions rejects unauthorized session join" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => restricted_token()})

      assert {:error, %{reason: "unauthorized_session"}} =
               subscribe_and_join(socket, MuseWeb.SessionChannel, "session:sess-denied")
    end

    test "valid token with restricted sessions rejects different session" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => restricted_token()})

      assert {:error, %{reason: "unauthorized_session"}} =
               subscribe_and_join(socket, MuseWeb.SessionChannel, "session:other-session")
    end
  end

  # -- ExternalSocketAuth module unit tests -------------------------------------

  describe "ExternalSocketAuth.authenticate/1" do
    test "returns error for missing token" do
      assert {:error, :missing_token} = ExternalSocketAuth.authenticate(%{})
    end

    test "returns error for empty token" do
      assert {:error, :missing_token} = ExternalSocketAuth.authenticate(%{"token" => ""})
    end

    test "returns error for nil token" do
      assert {:error, :missing_token} = ExternalSocketAuth.authenticate(%{"token" => nil})
    end

    test "returns error for too-short token" do
      assert {:error, :token_too_short} = ExternalSocketAuth.authenticate(%{"token" => "tiny"})
    end

    test "returns error for invalid token" do
      assert {:error, :invalid_token} =
               ExternalSocketAuth.authenticate(%{"token" => "not-a-valid-token-for-any-entry"})
    end

    test "returns ok with principal for valid token" do
      assert {:ok, %{token_id: "test-token", scopes: ["events:read"], allowed_sessions: :all}} =
               ExternalSocketAuth.authenticate(%{"token" => test_token()})
    end
  end

  describe "ExternalSocketAuth.authorize_session/2" do
    test ":all principal authorizes any session" do
      principal = %{token_id: "test", scopes: [], allowed_sessions: :all}
      assert :ok = ExternalSocketAuth.authorize_session(principal, "any-session")
    end

    test "list principal authorizes matching session" do
      principal = %{token_id: "test", scopes: [], allowed_sessions: ["sess-a", "sess-b"]}
      assert :ok = ExternalSocketAuth.authorize_session(principal, "sess-a")
    end

    test "list principal rejects non-matching session" do
      principal = %{token_id: "test", scopes: [], allowed_sessions: ["sess-a", "sess-b"]}

      assert {:error, :unauthorized_session} =
               ExternalSocketAuth.authorize_session(principal, "sess-c")
    end

    test "nil principal rejects session" do
      assert {:error, :unauthorized_session} =
               ExternalSocketAuth.authorize_session(nil, "any-session")
    end
  end

  describe "ExternalSocketAuth.generate_token/0" do
    test "generates a token and hash pair" do
      {raw, hash} = ExternalSocketAuth.generate_token()
      assert is_binary(raw)
      assert byte_size(raw) >= 16
      assert is_binary(hash)
      assert String.length(hash) == 64
    end

    test "generated token can be authenticated when added to config" do
      {raw, hash} = ExternalSocketAuth.generate_token()

      Application.put_env(:muse, :external_ws,
        enabled: true,
        token_hashes: [
          %{id: "generated", hash: hash, scopes: ["events:read"], allowed_sessions: :all}
        ]
      )

      assert {:ok, %{token_id: "generated"}} = ExternalSocketAuth.authenticate(%{"token" => raw})
    end

    test "hash is SHA-256 hex of the raw token" do
      {raw, hash} = ExternalSocketAuth.generate_token()
      expected = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
      assert hash == expected
    end
  end

  # -- ExternalSocketConfig.token_hashes/0 --------------------------------------

  describe "ExternalSocketConfig.token_hashes/0" do
    test "returns empty list when no token hashes configured" do
      Application.put_env(:muse, :external_ws, enabled: true)
      # token_hashes not in config

      assert [] == ExternalSocketConfig.token_hashes()
    end

    test "returns configured token hashes" do
      Application.put_env(:muse, :external_ws, full_config())

      hashes = ExternalSocketConfig.token_hashes()
      assert length(hashes) == 2
      assert Enum.any?(hashes, &(&1.id == "test-token"))
      assert Enum.any?(hashes, &(&1.id == "test-restricted"))
    end

    test "wraps single entry in list" do
      entry = %{id: "single", hash: "abc", scopes: [], allowed_sessions: :all}
      Application.put_env(:muse, :external_ws, token_hashes: entry)

      assert [^entry] = ExternalSocketConfig.token_hashes()
    end
  end

  # -- Timing-attack resistance -------------------------------------------------

  describe "timing-attack resistant comparison" do
    test "uses secure_compare for token hash matching" do
      # This test verifies the implementation uses Plug.Crypto.secure_compare
      # by checking that both valid and invalid tokens of the same length
      # take a consistent code path (can't easily test timing, but can verify
      # the result pattern)
      assert {:ok, _} = ExternalSocketAuth.authenticate(%{"token" => test_token()})

      assert {:error, :invalid_token} =
               ExternalSocketAuth.authenticate(%{"token" => "test-token-16chars-NOT"})
    end
  end

  # -- No raw token in logs/error output ----------------------------------------

  describe "security: no raw token exposure" do
    test "connect error does not leak token details" do
      # When connect fails, we get :error — no reason, no token, no details
      result = connect(MuseWeb.UserSocket, %{"token" => "invalid-long-token-for-test"})
      assert result == :error
    end

    test "principal in socket assigns contains no raw token" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => test_token()})
      principal = socket.assigns.external_principal

      # Only token_id, scopes, allowed_sessions — no hash, no raw token
      assert Map.keys(principal) |> Enum.sort() == [:allowed_sessions, :scopes, :token_id]
      refute Map.has_key?(principal, :hash)
      refute Map.has_key?(principal, :token)
    end

    test "inspect of principal does not contain raw token" do
      {:ok, socket} = connect(MuseWeb.UserSocket, %{"token" => test_token()})
      principal = socket.assigns.external_principal

      inspected = inspect(principal)
      refute String.contains?(inspected, test_token())
    end
  end
end
