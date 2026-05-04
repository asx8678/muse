defmodule Muse.Auth.CodexCache do
  import Bitwise

  @moduledoc """
  Reads and resolves bearer tokens from the Codex CLI auth cache file.

  Codex stores OAuth tokens in `~/.codex/auth.json`. This module reads that
  file, safely extracts a bearer token, checks file permissions, and returns a
  `Muse.Auth.Credential` struct.

  ## Supported JSON shapes

  The Codex cache file has evolved across versions. This module defensively
  supports the following shapes (listed in lookup preference order):

    * `{"access_token": "..."}` — top-level access token
    * `{"tokens": {"access_token": "..."}}` — nested under `tokens`
    * `{"auth": {"access_token": "..."}}` — nested under `auth`
    * `{"openai": {"access_token": "..."}}` — nested under `openai`
    * `{"id_token": "..."}` — top-level ID token (fallback; lower priority)

  `access_token` is always preferred over `id_token`. If neither is found, an
  `{:error, :no_token}` is returned.

  ## Security

    * No token values are ever logged, inspected, or included in error messages.
    * File permissions are checked: group/other readable or writable modes
      produce a `{:permissive_permissions, "0600 recommended"}` warning.
    * File reads are capped at 1 MB to prevent resource exhaustion.
  """

  alias Muse.Auth.Credential
  import Bitwise

  @default_filename ".codex/auth.json"
  @max_bytes 1_048_576

  @doc """
  Resolve a bearer credential from the Codex auth cache.

  ## Options

    * `:path` — explicit path to the auth JSON file. If given, `:home` is
      ignored.
    * `:home` — home directory to resolve `~/.codex/auth.json` from. Useful in
      tests to avoid reading the real home directory.
    * If neither `:path` nor `:home` is given, `System.user_home!/0` is used
      as the home directory at runtime.

  ## Returns

    * `{:ok, %Credential{}}` — on successful token extraction.
    * `{:error, reason}` — on any failure (missing file, invalid JSON,
      oversized, no token found, etc.). Error reasons are atoms or safe
      strings — **never** raw file contents or token values.

  ## Examples

      # Explicit path (safe for tests)
      Muse.Auth.CodexCache.resolve(path: "/tmp/test_auth.json")

      # Explicit home (safe for tests)
      Muse.Auth.CodexCache.resolve(home: "/tmp/fake_home")

      # Runtime default (reads real ~/.codex/auth.json)
      Muse.Auth.CodexCache.resolve()

  ## Warning

      Do not call `resolve/1` without `:path` or `:home` in test environments
      unless you intend to read from the real user home.
  """
  @spec resolve(keyword()) :: {:ok, Credential.t()} | {:error, atom() | String.t()}
  def resolve(opts \\ []) when is_list(opts) do
    path = resolve_path(opts)

    with {:ok, contents} <- read_safely(path),
         {:ok, decoded} <- decode_safely(contents),
         {:ok, token} <- extract_token(decoded),
         source_ref <- safe_path_label(path) do
      credential = %Credential{
        type: :bearer,
        value: token,
        source: :codex_cache,
        source_ref: source_ref,
        expires_at: parse_expiry(decoded),
        redacted: Credential.redact_value(token)
      }

      credential = attach_permission_warning(credential, path)
      {:ok, credential}
    end
  end

  # ---------------------------------------------------------------------------
  # Path resolution
  # ---------------------------------------------------------------------------

  defp resolve_path(opts) do
    cond do
      opts[:path] -> opts[:path]
      opts[:home] -> Path.join(opts[:home], @default_filename)
      true -> Path.join(System.user_home!(), @default_filename)
    end
  end

  # ---------------------------------------------------------------------------
  # File reading (size-capped, no raises)
  # ---------------------------------------------------------------------------

  defp read_safely(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= @max_bytes do
      File.read(path)
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :file_too_large}
    end
  end

  # ---------------------------------------------------------------------------
  # JSON decoding (no raises)
  # ---------------------------------------------------------------------------

  defp decode_safely(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json_shape}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  # ---------------------------------------------------------------------------
  # Token extraction
  #
  # Supported shapes (looked up in order):
  #   1. top-level "access_token"
  #   2. nested tokens.access_token
  #   3. nested auth.access_token
  #   4. nested openai.access_token
  #   5. top-level "id_token" (fallback)
  # ---------------------------------------------------------------------------

  defp extract_token(map) when is_map(map) do
    token =
      map["access_token"] ||
        get_in(map, ["tokens", "access_token"]) ||
        get_in(map, ["auth", "access_token"]) ||
        get_in(map, ["openai", "access_token"]) ||
        map["id_token"]

    case token do
      nil -> {:error, :no_token}
      t when is_binary(t) and t != "" -> {:ok, t}
      _ -> {:error, :no_token}
    end
  end

  # ---------------------------------------------------------------------------
  # Expiry parsing (best-effort, never raises)
  # ---------------------------------------------------------------------------

  defp parse_expiry(map) do
    expiry_raw =
      map["expires_at"] || get_in(map, ["tokens", "expires_at"]) ||
        get_in(map, ["auth", "expires_at"]) || get_in(map, ["openai", "expires_at"])

    case expiry_raw do
      nil ->
        nil

      value when is_integer(value) ->
        DateTime.from_unix(value)
        |> case do
          {:ok, dt} -> dt
          _ -> nil
        end

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Permission check (POSIX — group/other mode bits)
  # ---------------------------------------------------------------------------

  defp attach_permission_warning(credential, path) do
    with {:ok, stat} <- File.stat(path),
         mode <- stat.mode,
         permissive_bits <- band(mode, 0o0077),
         true <- permissive_bits != 0 do
      %{credential | warnings: [{:permissive_permissions, "0600 recommended"}]}
    else
      _ -> credential
    end
  end

  # ---------------------------------------------------------------------------
  # Safe path label (avoids leaking full paths in logs/errors)
  # ---------------------------------------------------------------------------

  defp safe_path_label(path) do
    basename = Path.basename(path)

    if String.contains?(path, ".codex/auth.json") do
      "~/.codex/auth.json"
    else
      basename
    end
  end
end
