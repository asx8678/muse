defmodule Muse.Execution.Env do
  @moduledoc """
  Safe child process environment construction.

  Replaces inherited BEAM environment with an allowlisted base, then
  merges user-provided overrides, then strips denylisted keys as
  defense-in-depth. Child commands never receive provider API keys or
  unrelated secrets by default.

  ## Allowlist (safe base)

  Only well-known, non-secret variables needed for local tool execution:

    * `PATH` — required for executable resolution
    * `HOME` — required for dotfile/config lookup
    * `USER`, `LOGNAME` — identity for filesystem permissions
    * `LANG`, `LC_ALL`, `LC_CTYPE` — locale (UTF-8 enforced)
    * `TERM` — terminal capabilities
    * `TMPDIR`, `TEMP`, `TMP` — temp directory
    * `MIX_ENV` — Elixir build mode
    * `ERL_FLAGS`, `ELIXIR_ERL_OPTIONS` — BEAM runtime flags

  ## Denylist (defense-in-depth)

  Patterns that are **always removed**, even if explicitly passed or on
  the allowlist. Covers common secret patterns:

    * Provider API keys: `OPENAI_*`, `ANTHROPIC_*`, `GITHUB_*`, `AWS_*`,
      `GOOGLE_*`, `AZURE_*`
    * Muse-internal secrets: `MUSE_*` prefix (all MUSE_ vars are stripped;
      non-secret MUSE config should use a different prefix or be passed
      via explicit non-MUSE_ overrides)
    * Secret-semantic keys: anything matching `token`, `secret`,
      `password`, `api_key`, `private_key`, `credential`
    * Proxy/network escape hatches: `HTTP_PROXY`, `HTTPS_PROXY`,
      `ALL_PROXY`, `NO_PROXY` (and lowercase variants)

  ## API

    * `port_env/2` — build `Port.open/2`-compatible env (charlist pairs
      + unset markers). **Use this for LocalRunner and TestRunner.**
    * `safe_env_map/2` — build a plain `%{String.t() => String.t()}`
      map. Useful for inspection, tests, and non-Port consumers.
    * `denylisted?/1` — check whether a key matches the denylist.
    * `redact_env/1` — produce a diagnostics-safe map with redacted
      values (keys visible, values replaced with `"[REDACTED]"`).

  ## Design

  Denylist is applied **last**, after allowlist filtering and user
  overrides. This ensures that even if a caller accidentally includes
  a secret key in the override map, it will be stripped. The denylist
  is the final safety gate.
  """

  @default_allowlist ~w(
    PATH HOME USER LOGNAME LANG LC_ALL LC_CTYPE TERM
    TMPDIR TEMP TMP MIX_ENV ERL_FLAGS ELIXIR_ERL_OPTIONS
  )

  @denylist_patterns [
    ~r/^OPENAI_/i,
    ~r/^ANTHROPIC_/i,
    ~r/^GITHUB_/i,
    ~r/^AWS_/i,
    ~r/^GOOGLE_/i,
    ~r/^AZURE_/i,
    ~r/^MUSE_/i,
    ~r/token$/i,
    ~r/token_/i,
    ~r/_token$/i,
    ~r/^token_/i,
    ~r/secret/i,
    ~r/password/i,
    ~r/passphrase/i,
    ~r/api[_-]?key/i,
    ~r/private[_-]?key/i,
    ~r/credential/i,
    ~r/auth[_-]?token/i,
    ~r/access[_-]?key/i,
    ~r/^(HTTP|HTTPS|ALL|NO|FTP|SOCKS)_PROXY$/i,
    ~r/^http_proxy$/i,
    ~r/^https_proxy$/i,
    ~r/^all_proxy$/i,
    ~r/^no_proxy$/i,
    ~r/^ftp_proxy$/i,
    ~r/^socks_proxy$/i,
    ~r/^socks_server$/i,
    ~r/DATABASE_URL/i
  ]

  @redacted_value "[REDACTED]"

  # -- Public API ----------------------------------------------------------------

  @doc """
  Build a `Port.open/2`-compatible env list with allowlist + denylist filtering.

  Returns a list of charlist pairs for set variables, plus `{key, false}`
  entries for variables that should be **unset** in the child process
  (to prevent inheritance from the BEAM environment).

  ## Options

    * `:allowlist` — list of env var names to allow from the system
      environment (default: `@default_allowlist`). Additional names
      beyond the default can expand the safe base.
    * `:inherit?` — if `true`, include allowlisted system env vars
      (default: `true`). Set to `false` for a fully minimal env.

  ## Examples

      # Default: safe allowlisted system env + overrides, denylisted last
      env = Muse.Execution.Env.port_env(%{"MIX_ENV" => "test"})

      # Fully minimal: no system inheritance, just overrides + safe defaults
      env = Muse.Execution.Env.port_env(%{}, inherit?: false)

  """
  @spec port_env(map(), keyword()) :: [{charlist(), charlist() | false}]
  def port_env(overrides \\ %{}, opts \\ [])

  def port_env(overrides, opts) when is_map(overrides) and is_list(opts) do
    allowlist = opts |> Keyword.get(:allowlist, @default_allowlist) |> MapSet.new()
    inherit? = Keyword.get(opts, :inherit?, true)

    base = if inherit?, do: allowlisted_system_env(allowlist), else: %{}

    env =
      base
      |> Map.merge(safe_defaults())
      |> Map.merge(stringify_map(overrides))
      |> strip_denylisted()

    # Port.open requires explicit unset markers for inherited vars
    # that should NOT be passed to the child process
    unset =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(env, &1))
      |> Enum.map(fn key -> {String.to_charlist(key), false} end)

    set =
      Enum.map(env, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(to_string(value))}
      end)

    unset ++ set
  end

  @doc """
  Build a plain map of safe environment variables.

  Same filtering logic as `port_env/2`, but returns a
  `%{String.t() => String.t()}` map without unset markers.
  Useful for inspection, testing, and non-Port consumers.

  ## Examples

      env_map = Muse.Execution.Env.safe_env_map(%{"MIX_ENV" => "test"})
      assert is_map(env_map)
      assert env_map["MIX_ENV"] == "test"
      refute Map.has_key?(env_map, "OPENAI_API_KEY")

  """
  @spec safe_env_map(map(), keyword()) :: %{String.t() => String.t()}
  def safe_env_map(overrides \\ %{}, opts \\ [])

  def safe_env_map(overrides, opts) when is_map(overrides) and is_list(opts) do
    allowlist = opts |> Keyword.get(:allowlist, @default_allowlist) |> MapSet.new()
    inherit? = Keyword.get(opts, :inherit?, true)

    base = if inherit?, do: allowlisted_system_env(allowlist), else: %{}

    base
    |> Map.merge(safe_defaults())
    |> Map.merge(stringify_map(overrides))
    |> strip_denylisted()
  end

  @doc """
  Check whether a key matches the denylist.

  Returns `true` if the key should be stripped regardless of source.
  Used for testing and validation.

  ## Examples

      iex> Muse.Execution.Env.denylisted?("OPENAI_API_KEY")
      true

      iex> Muse.Execution.Env.denylisted?("PATH")
      false

      iex> Muse.Execution.Env.denylisted?("MY_SECRET_TOKEN")
      true

  """
  @spec denylisted?(String.t()) :: boolean()
  def denylisted?(key) when is_binary(key) do
    Enum.any?(@denylist_patterns, &Regex.match?(&1, key))
  end

  @spec default_allowlist() :: [String.t()]
  def default_allowlist, do: @default_allowlist

  @spec denylist_patterns() :: [Regex.t()]
  def denylist_patterns, do: @denylist_patterns

  @doc """
  Produce a diagnostics-safe version of an env map with redacted values.

  Keys are preserved (for debugging which vars are set), but all values
  are replaced with `"[REDACTED]"`. Never log raw env maps — use this
  instead.

  ## Examples

      iex> Muse.Execution.Env.redact_env(%{"PATH" => "/usr/bin", "SECRET" => "abc123"})
      %{"PATH" => "[REDACTED]", "SECRET" => "[REDACTED]"}

  """
  @spec redact_env(map()) :: map()
  def redact_env(env) when is_map(env) do
    Map.new(env, fn {k, _v} -> {to_string(k), @redacted_value} end)
  end

  # -- Private -------------------------------------------------------------------

  defp allowlisted_system_env(allowlist) do
    System.get_env()
    |> Enum.filter(fn {key, _value} ->
      MapSet.member?(allowlist, key) and not denylisted?(key)
    end)
    |> Map.new()
  end

  defp safe_defaults do
    # Only set locale and PATH defaults. MIX_ENV is NOT forced here —
    # TestRunner forces MIX_ENV=test via overrides; LocalRunner preserves
    # the system's allowlisted MIX_ENV value.
    %{
      "LANG" => "C.UTF-8",
      "LC_ALL" => "C.UTF-8",
      "PATH" => System.get_env("PATH") || "/usr/bin:/bin"
    }
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp stringify_map(list) when is_list(list) do
    Map.new(list, fn
      {k, v} -> {to_string(k), to_string(v)}
      _ -> {"", ""}
    end)
    |> Map.delete("")
  end

  defp stringify_map(_), do: %{}

  defp strip_denylisted(env) do
    Enum.reject(env, fn {key, _value} -> denylisted?(key) end)
    |> Map.new()
  end
end
