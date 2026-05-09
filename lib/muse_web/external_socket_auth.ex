defmodule MuseWeb.ExternalSocketAuth do
  @moduledoc """
  Authentication and authorization for the optional external WebSocket.

  ## Token authentication

  External WebSocket clients must supply a `token` parameter when connecting.
  The supplied token is hashed with SHA-256 and compared against configured
  token hashes using `Plug.Crypto.secure_compare/2` to prevent timing attacks.

  Token hashes are stored in application config under
  `config :muse, :external_ws, token_hashes: [...]` — never raw token values
  (except transiently during `generate_token/0`).

  ## Authorization

  Each token is associated with a principal that defines which sessions it may
  access.  On successful authentication, a `%{token_id, scopes, allowed_sessions}`
  map is assigned to the socket as `:external_principal`.

  The `SessionChannel.join/3` callback checks the principal's `allowed_sessions`
  against the requested session_id.  The special value `:all` grants access to
  every session.

  ## Production fail-fast

  When the external socket is enabled in production but no token hashes are
  configured, `assert_configured!/0` raises at startup.  This ensures
  misconfiguration is caught before any client can connect unauthenticated.
  """

  alias MuseWeb.ExternalSocketConfig

  @type principal :: %{
          token_id: String.t(),
          scopes: [String.t()],
          allowed_sessions: [String.t()] | :all
        }

  @min_token_length 16

  # -- Public API --------------------------------------------------------------

  @doc """
  Authenticate a connection using the `token` param.

  Returns `{:ok, principal}` when a valid token is supplied, `{:error, reason}`
  otherwise.

  The supplied token is hashed before comparison — raw tokens are never stored
  in assigns, logs, or socket state.
  """
  @spec authenticate(map()) :: {:ok, principal()} | {:error, atom()}
  def authenticate(params) when is_map(params) do
    token = Map.get(params, "token")

    with :ok <- validate_token_present(token),
         :ok <- validate_token_length(token),
         {:ok, token_entry} <- find_token_entry(token) do
      {:ok, build_principal(token_entry)}
    end
  end

  @doc """
  Check whether a principal is authorized to access a given session.

  Returns `:ok` if allowed, `{:error, :unauthorized_session}` otherwise.
  """
  @spec authorize_session(principal(), String.t()) :: :ok | {:error, :unauthorized_session}
  def authorize_session(%{allowed_sessions: :all}, _session_id), do: :ok

  def authorize_session(%{allowed_sessions: sessions}, session_id) when is_list(sessions) do
    if session_id in sessions do
      :ok
    else
      {:error, :unauthorized_session}
    end
  end

  def authorize_session(_principal, _session_id), do: {:error, :unauthorized_session}

  @doc """
  Generate a random token and its corresponding SHA-256 hash.

  Returns `{raw_token, hash}`.  The raw token should be given to the client;
  the hash should be stored in configuration.

  **Only call this interactively or in test/setup code.**  Never log or persist
  the raw token.
  """
  @spec generate_token() :: {raw_token :: String.t(), hash :: String.t()}
  def generate_token do
    raw_token = :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
    hash = hash_token(raw_token)
    {raw_token, hash}
  end

  @doc """
  Verify that the external WebSocket is properly configured for production use.

  Raises if the socket is enabled but no token hashes are configured.
  Call this at application startup in `config/runtime.exs` or a supervised
  init callback.
  """
  @spec assert_configured!() :: :ok
  def assert_configured! do
    if ExternalSocketConfig.enabled?() and token_hashes() == [] do
      raise """
      External WebSocket is enabled but no token hashes are configured.

      Generate a token with:

          iex -S mix
          iex> {raw, hash} = MuseWeb.ExternalSocketAuth.generate_token()
          iex> IO.puts("Token: \#{raw}")
          iex> IO.puts("Hash:  \#{hash}")

      Then add the hash to config:

          config :muse, :external_ws,
            enabled: true,
            token_hashes: [
              %{
                id: "my-token",
                hash: "<hash from above>",
                scopes: ["events:read"],
                allowed_sessions: ["session-1", "session-2"]
              }
            ]

      Or disable the external socket:

          MUSE_EXTERNAL_WS= (unset or false)
      """
    end

    :ok
  end

  @doc """
  Returns the configured token hash entries.

  Each entry is a map with `:id`, `:hash`, `:scopes`, and `:allowed_sessions`.
  """
  @spec token_hashes() :: [map()]
  def token_hashes do
    ExternalSocketConfig.token_hashes()
  end

  # -- Private -----------------------------------------------------------------

  defp validate_token_present(nil), do: {:error, :missing_token}
  defp validate_token_present(""), do: {:error, :missing_token}
  defp validate_token_present(_token), do: :ok

  defp validate_token_length(token) when is_binary(token) do
    if byte_size(token) < @min_token_length do
      {:error, :token_too_short}
    else
      :ok
    end
  end

  defp validate_token_length(_token), do: {:error, :invalid_token}

  defp find_token_entry(token) when is_binary(token) do
    supplied_hash = hash_token(token)

    token_hashes()
    |> Enum.find_value(fn entry ->
      if Plug.Crypto.secure_compare(supplied_hash, entry[:hash] || "") do
        {:ok, entry}
      else
        nil
      end
    end)
    |> case do
      {:ok, entry} -> {:ok, entry}
      nil -> {:error, :invalid_token}
    end
  end

  defp find_token_entry(_token), do: {:error, :invalid_token}

  defp hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp build_principal(entry) do
    %{
      token_id: entry[:id] || "unknown",
      scopes: entry[:scopes] || [],
      allowed_sessions: entry[:allowed_sessions] || []
    }
  end
end
