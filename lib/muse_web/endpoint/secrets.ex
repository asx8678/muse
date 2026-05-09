defmodule MuseWeb.Endpoint.Secrets do
  @moduledoc """
  Production secret/salt validation and derivation for the Phoenix endpoint.

  In dev/test/smoke, deterministic local-only salts are configured directly
  in per-environment config files.  In production, salts are either derived
  from `MUSE_SECRET_KEY_BASE` (using `Plug.Crypto.KeyGenerator` with stable
  labels) or overridden via `MUSE_SIGNING_SALT` / `MUSE_LV_SIGNING_SALT`
  environment variables.

  ## Security model

    * `secret_key_base` — the primary secret; must be ≥ 64 bytes and never
      a placeholder/dev value.
    * `signing_salt` (cookie session) — read from endpoint config at runtime
      so release builds can override it in `config/runtime.exs`.
    * `live_view signing_salt` — same treatment; derived from
      `secret_key_base` in production.

  All three are validated in `validate_production!/0` which is called from
  `config/runtime.exs` before the application starts.
  """

  # Values that MUST NEVER appear in production config.
  @forbidden_secret_key_bases [
    "placeholder-secret-key-base-for-dev-do-not-use-in-prod-0000000000000000000000"
  ]

  @forbidden_salts [
    "dev-salt",
    "placeholder-signing-salt",
    "test-signing-salt",
    "smoke-signing-salt",
    "dev-lv-signing-salt",
    "test-lv-signing-salt",
    "smoke-lv-signing-salt"
  ]

  @forbidden_prefixes ["placeholder-", "dev-", "test-", "smoke-"]

  @doc """
  Validates that the production endpoint configuration uses secure,
  non-placeholder salts.  Raises with a clear error message if any
  value is missing, a known placeholder, or below the minimum length.

  Accepts an optional `endpoint_config` keyword list to validate
  explicitly.  When called without arguments (or with `nil`), reads
  the current value from `Application.get_env(:muse, MuseWeb.Endpoint)`.

  Call from `config/runtime.exs` by passing the config just assembled
  so validation operates on the runtime values rather than the
  compiled-in defaults.
  """
  @spec validate_production!(endpoint_config :: keyword() | nil) :: :ok | no_return()
  def validate_production!(endpoint_config \\ nil) do
    config = endpoint_config || Application.get_env(:muse, MuseWeb.Endpoint, [])

    secret_key_base = Keyword.get(config, :secret_key_base)
    validate_secret_key_base!(secret_key_base)

    signing_salt = Keyword.get(config, :signing_salt)
    validate_salt!("signing_salt", signing_salt)

    lv_config = Keyword.get(config, :live_view, [])
    lv_signing_salt = Keyword.get(lv_config, :signing_salt)
    validate_salt!("live_view signing_salt", lv_signing_salt)

    :ok
  end

  @doc """
  Derives a signing salt from `secret_key_base` using PBKDF2 with a stable
  label.  The same `secret_key_base` + `label` always produces the same
  salt, so redeployments preserve session validity.

  Returns a Base64-encoded string (22 bytes of key material encoded as
  30 characters, well above the 8-byte minimum for signing salts).
  """
  @spec derive_salt(secret_key_base :: String.t(), label :: String.t()) :: String.t()
  def derive_salt(secret_key_base, label) do
    key =
      Plug.Crypto.KeyGenerator.generate(
        secret_key_base,
        label,
        key_length: 22,
        iterations: 1000
      )

    Base.encode64(key, padding: false)
  end

  # -- Validation helpers -------------------------------------------------------

  defp validate_secret_key_base!(nil) do
    raise_production_error!(
      "secret_key_base is missing.",
      "Set MUSE_SECRET_KEY_BASE before starting the production release."
    )
  end

  defp validate_secret_key_base!(value) when is_binary(value) do
    if value in @forbidden_secret_key_bases do
      raise_production_error!(
        "secret_key_base uses a placeholder value.",
        "Generate a strong value with: mix phx.gen.secret"
      )
    end

    if byte_size(value) < 64 do
      raise_production_error!(
        "secret_key_base must be at least 64 bytes (got #{byte_size(value)}).",
        "Generate a strong value with: mix phx.gen.secret"
      )
    end

    :ok
  end

  defp validate_secret_key_base!(value) do
    raise_production_error!(
      "secret_key_base must be a string, got: #{inspect(value)}.",
      "Set MUSE_SECRET_KEY_BASE before starting the production release."
    )
  end

  defp validate_salt!(name, nil) do
    raise_production_error!(
      "#{name} is missing.",
      "Set MUSE_SECRET_KEY_BASE so salts can be derived, or set" <>
        " MUSE_SIGNING_SALT / MUSE_LV_SIGNING_SALT explicitly."
    )
  end

  defp validate_salt!(name, value) when is_binary(value) do
    if value in @forbidden_salts do
      raise_production_error!(
        "#{name} uses a placeholder/dev value (\"#{value}\") — not safe for production.",
        "Set MUSE_SECRET_KEY_BASE so salts can be derived, or set" <>
          " MUSE_SIGNING_SALT / MUSE_LV_SIGNING_SALT explicitly."
      )
    end

    if has_forbidden_prefix?(value) do
      raise_production_error!(
        "#{name} starts with a reserved prefix (\"#{prefix_of(value)}\") —" <>
          " not safe for production.",
        "Set MUSE_SECRET_KEY_BASE so salts can be derived, or set" <>
          " MUSE_SIGNING_SALT / MUSE_LV_SIGNING_SALT explicitly."
      )
    end

    if byte_size(value) < 8 do
      raise_production_error!(
        "#{name} must be at least 8 bytes (got #{byte_size(value)}).",
        "Set MUSE_SECRET_KEY_BASE so salts can be derived, or set" <>
          " MUSE_SIGNING_SALT / MUSE_LV_SIGNING_SALT explicitly."
      )
    end

    :ok
  end

  defp validate_salt!(name, value) do
    raise_production_error!(
      "#{name} must be a string, got: #{inspect(value)}.",
      "Set MUSE_SECRET_KEY_BASE so salts can be derived, or set" <>
        " MUSE_SIGNING_SALT / MUSE_LV_SIGNING_SALT explicitly."
    )
  end

  defp has_forbidden_prefix?(value) do
    Enum.any?(@forbidden_prefixes, &String.starts_with?(value, &1))
  end

  defp prefix_of(value) do
    @forbidden_prefixes
    |> Enum.find(&String.starts_with?(value, &1))
    |> String.trim_trailing("-")
  end

  defp raise_production_error!(detail, remediation) do
    raise """

    Production configuration error: #{detail}

    #{remediation}

    See MuseWeb.Endpoint.Secrets for documentation.
    """
  end
end
