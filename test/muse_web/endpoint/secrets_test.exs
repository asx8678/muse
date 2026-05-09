defmodule MuseWeb.Endpoint.SecretsTest do
  use ExUnit.Case, async: true

  alias MuseWeb.Endpoint.Secrets

  # ---------------------------------------------------------------------------
  # derive_salt/2
  # ---------------------------------------------------------------------------

  describe "derive_salt/2" do
    test "produces a Base64-encoded string of sufficient length" do
      salt =
        Secrets.derive_salt(
          "a-reasonably-long-secret-key-base-value-at-least-64-bytes-long-padding",
          "test-label"
        )

      assert is_binary(salt)
      assert byte_size(salt) >= 8
      # Base64 without padding — no trailing '='
      refute String.ends_with?(salt, "=")
    end

    test "is deterministic — same inputs always produce the same salt" do
      skb = "a-reasonably-long-secret-key-base-value-at-least-64-bytes-long-padding"

      salt1 = Secrets.derive_salt(skb, "stable-label")
      salt2 = Secrets.derive_salt(skb, "stable-label")

      assert salt1 == salt2
    end

    test "different labels produce different salts" do
      skb = "a-reasonably-long-secret-key-base-value-at-least-64-bytes-long-padding"

      salt_a = Secrets.derive_salt(skb, "label-a")
      salt_b = Secrets.derive_salt(skb, "label-b")

      refute salt_a == salt_b
    end

    test "different secret_key_bases produce different salts" do
      skb_a = "a-reasonably-long-secret-key-base-value-at-least-64-bytes-long-a"
      skb_b = "a-reasonably-long-secret-key-base-value-at-least-64-bytes-long-b"

      salt_a = Secrets.derive_salt(skb_a, "same-label")
      salt_b = Secrets.derive_salt(skb_b, "same-label")

      refute salt_a == salt_b
    end
  end

  # ---------------------------------------------------------------------------
  # validate_production!/0 — secret_key_base
  # ---------------------------------------------------------------------------

  describe "validate_production!/0 — secret_key_base" do
    setup do
      original = Application.get_env(:muse, MuseWeb.Endpoint)
      on_exit(fn -> restore_endpoint!(original) end)
      :ok
    end

    test "rejects missing secret_key_base" do
      put_endpoint_config!(
        secret_key_base: nil,
        signing_salt: "prod-salt-1234",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert_raise RuntimeError, ~r/secret_key_base is missing/, fn ->
        Secrets.validate_production!()
      end
    end

    test "rejects placeholder secret_key_base" do
      put_endpoint_config!(
        secret_key_base:
          "placeholder-secret-key-base-for-dev-do-not-use-in-prod-0000000000000000000000",
        signing_salt: "prod-salt-1234",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert_raise RuntimeError, ~r/placeholder/, fn ->
        Secrets.validate_production!()
      end
    end

    test "rejects short secret_key_base" do
      put_endpoint_config!(
        secret_key_base: "too-short",
        signing_salt: "prod-salt-1234",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert_raise RuntimeError, ~r/at least 64 bytes/, fn ->
        Secrets.validate_production!()
      end
    end

    test "accepts a strong secret_key_base" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "prod-salt-1234",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert Secrets.validate_production!() == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # validate_production!/0 — signing_salt (cookie)
  # ---------------------------------------------------------------------------

  describe "validate_production!/0 — signing_salt" do
    setup do
      original = Application.get_env(:muse, MuseWeb.Endpoint)
      on_exit(fn -> restore_endpoint!(original) end)
      :ok
    end

    test "rejects missing signing_salt" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: nil,
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert_raise RuntimeError, ~r/signing_salt is missing/, fn ->
        Secrets.validate_production!()
      end
    end

    test "rejects 'dev-salt' placeholder" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "dev-salt",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert_raise RuntimeError, ~r/placeholder\/dev value/, fn ->
        Secrets.validate_production!()
      end
    end

    test "rejects any 'dev-' prefixed salt" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "dev-anything-else",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert_raise RuntimeError, ~r/reserved prefix/, fn ->
        Secrets.validate_production!()
      end
    end

    test "rejects 'placeholder-' prefixed salt" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "placeholder-xyz",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert_raise RuntimeError, ~r/reserved prefix/, fn ->
        Secrets.validate_production!()
      end
    end

    test "rejects 'test-' prefixed salt" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "test-abc123",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert_raise RuntimeError, ~r/reserved prefix/, fn ->
        Secrets.validate_production!()
      end
    end

    test "rejects short signing_salt" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "short",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert_raise RuntimeError, ~r/at least 8 bytes/, fn ->
        Secrets.validate_production!()
      end
    end

    test "accepts a valid signing_salt" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "prod-salt-1234567890",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert Secrets.validate_production!() == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # validate_production!/0 — live_view signing_salt
  # ---------------------------------------------------------------------------

  describe "validate_production!/0 — live_view signing_salt" do
    setup do
      original = Application.get_env(:muse, MuseWeb.Endpoint)
      on_exit(fn -> restore_endpoint!(original) end)
      :ok
    end

    test "rejects missing live_view signing_salt" do
      # Explicitly set live_view with no signing_salt key
      config = Application.get_env(:muse, MuseWeb.Endpoint, []) || []
      config = Keyword.put(config, :secret_key_base, String.duplicate("a", 64))
      config = Keyword.put(config, :signing_salt, "prod-salt-1234")
      config = Keyword.put(config, :live_view, [])
      Application.put_env(:muse, MuseWeb.Endpoint, config)

      assert_raise RuntimeError, ~r/live_view signing_salt is missing/, fn ->
        Secrets.validate_production!()
      end
    end

    test "rejects 'dev-lv-signing-salt' placeholder" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "prod-salt-1234",
        live_view: [signing_salt: "dev-lv-signing-salt"]
      )

      assert_raise RuntimeError, ~r/placeholder\/dev value/, fn ->
        Secrets.validate_production!()
      end
    end

    test "rejects 'placeholder-' prefixed live_view salt" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "prod-salt-1234",
        live_view: [signing_salt: "placeholder-lv-salt"]
      )

      assert_raise RuntimeError, ~r/reserved prefix/, fn ->
        Secrets.validate_production!()
      end
    end

    test "accepts a valid live_view signing_salt" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "prod-salt-1234",
        live_view: [signing_salt: "prod-lv-salt-1234"]
      )

      assert Secrets.validate_production!() == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end: valid production config passes
  # ---------------------------------------------------------------------------

  describe "validate_production!/0 — full valid config" do
    setup do
      original = Application.get_env(:muse, MuseWeb.Endpoint)
      on_exit(fn -> restore_endpoint!(original) end)
      :ok
    end

    test "accepts a fully valid production configuration" do
      put_endpoint_config!(
        secret_key_base: String.duplicate("a", 64),
        signing_salt: "prod-derived-salt-abc123456789",
        live_view: [signing_salt: "prod-derived-lv-salt-xyz987654321"]
      )

      assert Secrets.validate_production!() == :ok
    end

    test "accepts salts derived from secret_key_base" do
      skb = String.duplicate("a", 64)
      signing_salt = Secrets.derive_salt(skb, "muse-cookie-signing-salt")
      lv_salt = Secrets.derive_salt(skb, "muse-liveview-signing-salt")

      put_endpoint_config!(
        secret_key_base: skb,
        signing_salt: signing_salt,
        live_view: [signing_salt: lv_salt]
      )

      assert Secrets.validate_production!() == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Dev/test/smoke config sanity
  # ---------------------------------------------------------------------------

  describe "dev/test/smoke config has deterministic salts" do
    test "dev config has deterministic secret_key_base and salts" do
      endpoint_config = Application.get_env(:muse, MuseWeb.Endpoint, [])

      skb = Keyword.get(endpoint_config, :secret_key_base)
      assert is_binary(skb)
      assert byte_size(skb) >= 64

      signing_salt = Keyword.get(endpoint_config, :signing_salt)
      assert is_binary(signing_salt)

      lv_config = Keyword.get(endpoint_config, :live_view, [])
      lv_salt = Keyword.get(lv_config, :signing_salt)
      assert is_binary(lv_salt)
    end
  end

  # ---------------------------------------------------------------------------
  # Endpoint session_options/0 reads from config
  # ---------------------------------------------------------------------------

  describe "MuseWeb.Endpoint.session_options/0" do
    setup do
      original = Application.get_env(:muse, MuseWeb.Endpoint)
      on_exit(fn -> restore_endpoint!(original) end)
      :ok
    end

    test "returns session options with signing_salt from config" do
      put_endpoint_config!(signing_salt: "configured-salt-value")

      opts = MuseWeb.Endpoint.session_options()

      assert Keyword.get(opts, :store) == :cookie
      assert Keyword.get(opts, :key) == "_muse_key"
      assert Keyword.get(opts, :signing_salt) == "configured-salt-value"
    end

    test "falls back to 'dev-salt' when signing_salt is not configured" do
      # Remove signing_salt from config
      config = Application.get_env(:muse, MuseWeb.Endpoint, [])
      config = Keyword.delete(config, :signing_salt)
      Application.put_env(:muse, MuseWeb.Endpoint, config)

      opts = MuseWeb.Endpoint.session_options()

      assert Keyword.get(opts, :signing_salt) == "dev-salt"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp put_endpoint_config!(overrides) do
    base = Application.get_env(:muse, MuseWeb.Endpoint, []) || []

    config =
      Enum.reduce(overrides, base, fn
        {:live_view, lv_overrides}, acc ->
          existing_lv = Keyword.get(acc, :live_view, [])
          Keyword.put(acc, :live_view, Keyword.merge(existing_lv, lv_overrides))

        {key, value}, acc ->
          Keyword.put(acc, key, value)
      end)

    Application.put_env(:muse, MuseWeb.Endpoint, config)
  end

  defp restore_endpoint!(original) do
    if original do
      Application.put_env(:muse, MuseWeb.Endpoint, original)
    else
      Application.delete_env(:muse, MuseWeb.Endpoint)
    end
  end
end
