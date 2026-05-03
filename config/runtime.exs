import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("MUSE_SECRET_KEY_BASE") ||
      raise """
      environment variable MUSE_SECRET_KEY_BASE is missing.

      Generate one with:

          mix phx.gen.secret

      Set MUSE_SECRET_KEY_BASE before starting the production release.
      """

  if byte_size(secret_key_base) < 64 do
    raise """
    environment variable MUSE_SECRET_KEY_BASE must be at least 64 bytes.

    Generate a strong value with:

        mix phx.gen.secret
    """
  end

  config :muse, MuseWeb.Endpoint, secret_key_base: secret_key_base
end
