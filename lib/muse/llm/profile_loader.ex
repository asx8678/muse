defmodule Muse.LLM.ProfileLoader do
  @moduledoc """
  Loads LLM provider profiles from `~/.muse/config.json` and secrets from
  `~/.muse/secrets.json`.

  Profiles are generic names (e.g. `default`, `fast`, `creative`) that group
  provider settings so you don't need a sea of `MUSE_*` environment variables.
  Secrets (API keys, tokens, passwords) live in a separate file so you can
  keep `config.json` under version control or share it safely.

  ## File format

  `~/.muse/config.json`:

      {
        "profiles": {
          "default": {
            "provider": "openai_compatible",
            "model": "gpt-4o",
            "base_url": "https://api.openai.com/v1",
            "api_key": "my_openai_key",
            "tools_enabled": true,
            "structured_outputs_enabled": true
          },
          "wafer": {
            "provider": "openai_compatible",
            "model": "glm-5.1",
            "base_url": "https://api.wafer.ai/v1",
            "api_key": "my_wafer_key",
            "tools_enabled": false,
            "structured_outputs_enabled": false
          }
        }
      }

  `~/.muse/secrets.json`:

      {
        "my_openai_key": "sk-...",
        "my_wafer_key": "wafer-..."
      }

  The `api_key` field may be:

    * a literal key (discouraged — use `secrets.json` instead)
    * an env-var reference in the form `${VAR_NAME}` or `$VAR_NAME`
    * a reference to a key in `secrets.json` — the loader looks up the value
      automatically and substitutes it

  ## Security

  `~/.muse/secrets.json` contains credentials. After creation its permissions
  are set to `600` (owner read/write only). If the file is ever found with
  broader permissions, a warning is emitted on every load.

  ## Active profile

  The active profile name is read from the `MUSE_PROFILE` environment
  variable and falls back to `"default"` when unset.  Zero-arity functions
  such as `get_profile/0`, `apply_profile/0`, and `merged_env/0` use this
  active name automatically.

  If the config file does not exist, all functions return `{:error, :not_found}`
  so callers can fall back to standard environment variables safely.  Call
  `ensure_initialized/0` before loading if you want missing files to be
  created with empty or sensible default structures.
  """

  @default_config_path "~/.muse/config.json"
  @default_secrets_path "~/.muse/secrets.json"

  # ---------------------------------------------------------------------------
  # Public API — initialization
  # ---------------------------------------------------------------------------

  @doc """
  Ensures the `~/.muse/` directory and both configuration files exist.

  Missing files are created with empty or sensible default structures.
  `secrets.json` is created with permissions `600`.

  Returns `:ok`.
  """
  @spec ensure_initialized() :: :ok
  def ensure_initialized do
    ensure_initialized(@default_config_path, @default_secrets_path)
  end

  @spec ensure_initialized(String.t(), String.t()) :: :ok
  def ensure_initialized(config_path, secrets_path) do
    config_path = Path.expand(config_path)
    secrets_path = Path.expand(secrets_path)
    dir = Path.dirname(config_path)

    unless File.dir?(dir) do
      File.mkdir_p!(dir)
    end

    unless File.exists?(config_path) do
      init_config_file(config_path)
    end

    unless File.exists?(secrets_path) do
      init_secrets_file(secrets_path)
      # Best-effort chmod 600; ignore failures on Windows or restricted FS
      _ = File.chmod(secrets_path, 0o600)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Public API — loading
  # ---------------------------------------------------------------------------

  @doc """
  Loads all profiles from the config file.

  Returns `{:ok, %{profile_name => profile_map}}` or `{:error, reason}`.
  If the file does not exist, returns `{:error, :not_found}`.
  """
  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    load(@default_config_path)
  end

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    path = Path.expand(path)

    with {:ok, content} <- read_file(path),
         {:ok, decoded} <- Jason.decode(content),
         {:ok, profiles} <- extract_profiles(decoded) do
      {:ok, profiles}
    end
  end

  @doc """
  Loads secrets from the secrets file.

  Supports both JSON and TOML/INI formats:

      # JSON
      { "my_key": "my_value" }

      # TOML/INI
      [section]
      my_key = my_value

  Returns `{:ok, %{secret_name => secret_value}}` or `{:error, reason}`.
  If the file does not exist, returns `{:ok, %{}}` so callers can proceed
  with literal values or env-var references only.
  """
  @spec load_secrets() :: {:ok, map()} | {:error, term()}
  def load_secrets do
    load_secrets(@default_secrets_path)
  end

  @spec load_secrets(String.t()) :: {:ok, map()} | {:error, term()}
  def load_secrets(path) do
    path = Path.expand(path)

    case File.read(path) do
      {:ok, content} ->
        warn_permissions(path)

        case Jason.decode(content) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, decoded}

          {:ok, _} ->
            {:error, :invalid_secrets_format}

          {:error, _} ->
            # Not valid JSON — try TOML/INI format
            parse_toml_secrets(content)
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the currently active profile name.

  Reads `MUSE_PROFILE` from the environment and falls back to `"default"`.
  """
  @spec current_profile_name() :: String.t()
  def current_profile_name do
    System.get_env("MUSE_PROFILE", "default")
  end

  @doc """
  Returns the active profile with env-var and secrets references resolved.

  Uses `current_profile_name/0` to determine which profile to load and
  the default config/secrets paths (`~/.muse/config.json` and
  `~/.muse/secrets.json`).

  Returns `{:ok, profile_map}` or `{:error, reason}`.
  """
  @spec get_profile() :: {:ok, map()} | {:error, term()}
  def get_profile do
    get_profile(current_profile_name(), @default_config_path, @default_secrets_path)
  end

  @doc """
  Returns a single profile by name with `${ENV_VAR}` and secrets references
  resolved.

  Accepts an optional `config_path` (defaults to `~/.muse/config.json`) and
  an optional `secrets_path` (defaults to `~/.muse/secrets.json`).

  Returns `{:ok, profile_map}` or `{:error, reason}`.
  """
  @spec get_profile(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_profile(
        name,
        config_path \\ @default_config_path,
        secrets_path \\ @default_secrets_path
      ) do
    with {:ok, profiles} <- load(config_path),
         {:ok, secrets} <- load_secrets(secrets_path) do
      case Map.fetch(profiles, name) do
        {:ok, profile} -> {:ok, resolve_profile(profile, secrets)}
        :error -> {:error, :profile_not_found}
      end
    end
  end

  @doc """
  Applies the active profile by setting the standard `MUSE_*` environment
  variables that the rest of the app already reads.

  Uses `current_profile_name/0` and the default config/secrets paths.

  Returns `:ok` on success.  This is a side-effecting operation; use it at
  application startup or before initiating a session.
  """
  @spec apply_profile() :: :ok | {:error, term()}
  def apply_profile do
    apply_profile(current_profile_name(), @default_config_path, @default_secrets_path)
  end

  @doc """
  Applies a profile by setting the standard `MUSE_*` environment variables
  that the rest of the app already reads.

  Accepts optional `config_path` and `secrets_path`.

  Returns `:ok` on success.  This is a side-effecting operation; use it at
  application startup or before initiating a session.
  """
  @spec apply_profile(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def apply_profile(
        name,
        config_path \\ @default_config_path,
        secrets_path \\ @default_secrets_path
      ) do
    with {:ok, profile} <- get_profile(name, config_path, secrets_path) do
      profile
      |> to_env_map()
      |> Enum.each(fn {k, v} ->
        existing = System.get_env(k)

        if existing != nil and existing != "" and existing != v do
          IO.warn("Muse profile overriding #{k} (previous value was set)")
        end

        System.put_env(k, v)
      end)

      :ok
    end
  end

  @doc """
  Converts a loaded profile into a `MUSE_*` env map.

  The returned map can be passed directly to `Muse.Config.llm_provider_config/1`
  or merged with `System.get_env/0`.
  """
  @spec to_env_map(map()) :: %{String.t() => String.t()}
  def to_env_map(profile) do
    base = %{
      "MUSE_PROVIDER" => profile["provider"] || "",
      "MUSE_MODEL" => profile["model"] || "",
      "MUSE_TOOLS" => boolean_to_string(profile["tools_enabled"]),
      "MUSE_STRUCTURED_OUTPUTS" => boolean_to_string(profile["structured_outputs_enabled"]),
      "MUSE_WIRE_API" => profile["wire_api"] || ""
    }

    base
    |> maybe_put_base_url(profile)
    |> maybe_put_api_key(profile)
  end

  @doc """
  Returns a merged environment map containing `System.get_env/0` plus the
  active profile's overrides.

  Uses `current_profile_name/0` and the default config/secrets paths.

  Useful for pure callers that want to pass a complete env map to
  `Muse.Config.llm_provider_config/1` without mutating the OS environment.
  """
  @spec merged_env() :: {:ok, map()} | {:error, term()}
  def merged_env do
    merged_env(current_profile_name(), @default_config_path, @default_secrets_path)
  end

  @doc """
  Returns a merged environment map containing `System.get_env/0` plus the
  profile-specific overrides.

  Accepts optional `config_path` and `secrets_path`.

  Useful for pure callers that want to pass a complete env map to
  `Muse.Config.llm_provider_config/1` without mutating the OS environment.
  """
  @spec merged_env(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def merged_env(name, config_path \\ @default_config_path, secrets_path \\ @default_secrets_path) do
    with {:ok, profile} <- get_profile(name, config_path, secrets_path) do
      {:ok, Map.merge(System.get_env(), to_env_map(profile))}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp init_config_file(path) do
    default = %{
      "profiles" => %{
        "default" => %{
          "provider" => "fake",
          "model" => "fake-planning-model",
          "tools_enabled" => true,
          "structured_outputs_enabled" => true
        }
      }
    }

    File.write!(path, Jason.encode!(default, pretty: true))
  end

  defp init_secrets_file(path) do
    File.write!(path, Jason.encode!(%{}, pretty: true))
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_toml_secrets(content) when is_binary(content) do
    lines = String.split(content, "\n")

    # Separate meaningful lines from empties/comments/sections
    {kv_lines, non_kv_lines} =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.split_with(&String.contains?(&1, "="))

    # If there were non-empty, non-comment lines but none were key=value,
    # the content is probably garbage, not TOML
    if Enum.empty?(kv_lines) and not Enum.empty?(non_kv_lines) do
      {:error, :invalid_secrets_format}
    else
      result =
        Map.new(kv_lines, fn line ->
          [key, value] = String.split(line, "=", parts: 2)
          {String.trim(key), String.trim(value)}
        end)

      {:ok, result}
    end
  end

  defp extract_profiles(%{"profiles" => profiles}) when is_map(profiles),
    do: {:ok, profiles}

  defp extract_profiles(_), do: {:error, :missing_profiles_key}

  defp resolve_profile(profile, secrets) when is_map(profile) do
    profile
    |> Enum.map(fn {k, v} -> {k, resolve_value(v, secrets)} end)
    |> Map.new()
  end

  defp resolve_value(value, _secrets) when not is_binary(value), do: value

  defp resolve_value("${" <> rest, _secrets) do
    var_name = String.trim_trailing(rest, "}")
    System.get_env(var_name)
  end

  defp resolve_value("$" <> var_name, _secrets) do
    System.get_env(var_name)
  end

  defp resolve_value(value, secrets) do
    Map.get(secrets, value, value)
  end

  defp warn_permissions(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} when Bitwise.band(mode, 0o077) != 0 ->
        IO.warn(
          "#{path} permissions are #{Integer.to_string(mode, 8)}. " <>
            "Run `chmod 600 #{path}` so other users cannot read your secrets."
        )

      _ ->
        :ok
    end
  end

  defp maybe_put_base_url(env_map, %{"base_url" => url}) when is_binary(url) and url != "" do
    key = base_url_key(env_map["MUSE_PROVIDER"])
    Map.put(env_map, key, url)
  end

  defp maybe_put_base_url(env_map, _), do: env_map

  defp maybe_put_api_key(env_map, %{"api_key" => key}) when is_binary(key) and key != "" do
    env_var = api_key_env_var(env_map["MUSE_PROVIDER"])
    Map.put(env_map, env_var, key)
  end

  defp maybe_put_api_key(env_map, _), do: env_map

  defp base_url_key("openai_compatible"), do: "MUSE_OPENAI_BASE_URL"
  defp base_url_key("openrouter"), do: "MUSE_OPENROUTER_BASE_URL"
  defp base_url_key("ollama"), do: "MUSE_OLLAMA_BASE_URL"
  defp base_url_key("anthropic"), do: "MUSE_ANTHROPIC_BASE_URL"
  defp base_url_key(_), do: "MUSE_BASE_URL"

  defp api_key_env_var("openai_compatible"), do: "MUSE_OPENAI_API_KEY"
  defp api_key_env_var("openrouter"), do: "MUSE_OPENROUTER_API_KEY"
  defp api_key_env_var("anthropic"), do: "MUSE_ANTHROPIC_API_KEY"
  defp api_key_env_var(_), do: "MUSE_API_KEY"

  defp boolean_to_string(true), do: "true"
  defp boolean_to_string(false), do: "false"
  defp boolean_to_string(nil), do: ""
  defp boolean_to_string(other), do: to_string(other)
end
