defmodule Muse.Auth.Status do
  @moduledoc """
  Read-only, redacted authentication status rendering.

  This module powers `/auth status` for CLI, TUI, and Web command dispatch. It is
  intentionally conservative:

    * API-key checks use only explicit context data by default.
    * Bearer commands are never executed.
    * Codex cache files are never read.
    * Precomputed status may be injected through context and is sanitized before
      rendering.

  The returned string is human-readable and safe for user-facing command output.
  """

  alias Muse.Auth.{ApiKey, Credential}
  alias Muse.LLM.ProviderConfig

  @default_env_key "MUSE_OPENAI_API_KEY"
  @redacted "[REDACTED]"

  @type context :: map()
  @type provider_source :: String.t()

  @doc """
  Render a human-readable auth status summary from dispatcher context.

  Recognized context keys (atom or string):

    * `:provider_config`
    * `:llm_provider_config`
    * `:auth_status` — precomputed map/list/credential, sanitized before output
    * `:env` / `:env_map` — explicit env map for safe API-key status checks
    * `:api_key` — explicit API key, redacted if present
    * `:allow_system_env?` / `:auth_status_allow_system_env?` — opt-in only

  No bearer command or Codex cache resolver is invoked by this function.
  """
  @spec render(context()) :: String.t()
  def render(context \\ %{})

  def render(context) when is_map(context) do
    context
    |> render_lines()
    |> Enum.join("\n")
    |> safe_binary()
  end

  def render(_context), do: render(%{})

  defp render_lines(context) do
    precomputed = context_value(context, :auth_status)

    case provider_config(context) do
      {:ok, config, source} ->
        config_status_lines(config, source, context, precomputed)

      {:error, reason, source} ->
        [
          "Auth status: unknown (config error from #{safe_text(source)}: #{safe_text(reason)})."
          | precomputed_lines(precomputed)
        ]
    end
  end

  # -- Provider config resolution ---------------------------------------------

  defp provider_config(context) do
    cond do
      has_context_key?(context, :provider_config) ->
        context
        |> context_value(:provider_config)
        |> normalize_provider_config("context.provider_config")

      has_context_key?(context, :llm_provider_config) ->
        context
        |> context_value(:llm_provider_config)
        |> normalize_provider_config("context.llm_provider_config")

      true ->
        case Muse.Config.llm_provider_config(%{}) do
          {:ok, %ProviderConfig{} = config} ->
            {:ok, config, "Muse.Config.llm_provider_config/1"}

          {:ok, config} when is_map(config) ->
            {:ok, config, "Muse.Config.llm_provider_config/1"}

          {:error, reason} ->
            {:error, reason, "Muse.Config.llm_provider_config/1"}

          other ->
            {:error, {:unexpected_config_result, other}, "Muse.Config.llm_provider_config/1"}
        end
    end
  rescue
    exception ->
      {:error, Exception.message(exception), "Muse.Config.llm_provider_config/1"}
  end

  defp normalize_provider_config({:ok, config}, source),
    do: normalize_provider_config(config, source)

  defp normalize_provider_config({:error, reason}, source), do: {:error, reason, source}
  defp normalize_provider_config(%ProviderConfig{} = config, source), do: {:ok, config, source}
  defp normalize_provider_config(config, source) when is_map(config), do: {:ok, config, source}
  defp normalize_provider_config(nil, source), do: {:error, :missing_provider_config, source}

  defp normalize_provider_config(other, source) do
    {:error, {:unsupported_provider_config, safe_term(other)}, source}
  end

  # -- Status rendering --------------------------------------------------------

  defp config_status_lines(config, source, context, precomputed) do
    if is_fake?(config) do
      ["Auth status: fake provider uses no authentication." | precomputed_lines(precomputed)]
    else
      config_auth_status_lines(config, source, context, precomputed)
    end
  end

  defp config_auth_status_lines(config, source, context, precomputed) do
    auth_mode = auth_mode(config)

    lines =
      case auth_mode do
        :none -> no_auth_lines(config, source)
        :api_key -> api_key_lines(config, source, context)
        :bearer_command -> bearer_command_lines(config, source)
        :codex_cache -> codex_cache_lines(config, source)
        :openai_oauth -> oauth_lines(config, source)
        other -> unknown_auth_lines(config, source, other)
      end

    lines ++ precomputed_lines(precomputed)
  end

  defp no_auth_lines(config, source) do
    [
      "Auth status: #{provider_display(config)} uses no authentication.",
      "Provider: #{provider_display(config)}",
      "Config source: #{source}",
      "Auth mode: none",
      "Status: not_required",
      "Warnings: none"
    ]
  end

  defp api_key_lines(config, source, context) do
    env_key = env_key(config)

    base = [
      "Provider: #{provider_display(config)}",
      "Config source: #{source}",
      "Auth mode: api_key",
      "Env key: #{env_key}"
    ]

    case resolve_api_key(config, context, env_key) do
      {:ok, %Credential{} = credential} ->
        ["Auth status: #{provider_display(config)} api_key configured." | base] ++
          [
            "Status: configured",
            "Credential source: #{credential_source_label(credential.source)}",
            "Credential: #{credential.redacted || Credential.redact_value(credential.value)}",
            warnings_line(credential.warnings)
          ]

      {:error, {:missing, missing_env_key}} ->
        ["Auth status: #{provider_display(config)} api_key missing." | base] ++
          [
            "Status: missing",
            "Credential source: #{missing_source_label(context)}",
            "Warnings: #{missing_env_key} is not configured in the provided status context."
          ]

      {:error, {:empty, source_label}} ->
        ["Auth status: #{provider_display(config)} api_key missing." | base] ++
          [
            "Status: missing",
            "Credential source: #{source_label}",
            "Warnings: configured API key source is empty."
          ]

      {:error, reason} ->
        ["Auth status: #{provider_display(config)} api_key unknown." | base] ++
          [
            "Status: unknown",
            "Credential source: #{missing_source_label(context)}",
            "Warnings: unable to resolve API key status safely (#{safe_text(reason)})."
          ]
    end
  end

  defp bearer_command_lines(config, source) do
    configured? = present_string?(config_field(config, :bearer_command))
    status = if configured?, do: "configured", else: "missing"

    [
      "Auth status: #{provider_display(config)} bearer_command #{status} (not executed).",
      "Provider: #{provider_display(config)}",
      "Config source: #{source}",
      "Auth mode: bearer_command",
      "Status: #{status}",
      "Credential source: bearer_command (not executed)",
      "Warnings: bearer commands are not executed by /auth status. Inject :auth_status for precomputed credential state."
    ]
  end

  defp codex_cache_lines(config, source) do
    [
      "Auth status: #{provider_display(config)} codex_cache unknown (not read).",
      "Provider: #{provider_display(config)}",
      "Config source: #{source}",
      "Auth mode: codex_cache",
      "Status: unknown",
      "Credential source: codex_cache (not read)",
      "Warnings: Codex cache files are not read by /auth status. Inject :auth_status for precomputed credential state."
    ]
  end

  defp oauth_lines(config, source) do
    [
      "Auth status: #{provider_display(config)} openai_oauth (reads from Muse config dir auth.json).",
      "Provider: #{provider_display(config)}",
      "Config source: #{source}",
      "Auth mode: openai_oauth",
      "Expected location: ~/.muse/auth.json or ~/Documents/.muse/auth.json (Codex JSON shape)",
      "Credential source: oauth (resolved at request time via ConfigDir)",
      "Note: /auth status does not perform network or token refresh; actual resolution happens on first LLM call."
    ]
  end

  defp unknown_auth_lines(config, source, auth_mode) do
    [
      "Auth status: #{provider_display(config)} auth mode unknown.",
      "Provider: #{provider_display(config)}",
      "Config source: #{source}",
      "Auth mode: #{auth_label(auth_mode)}",
      "Status: unknown",
      "Warnings: auth mode is not recognized by /auth status."
    ]
  end

  defp precomputed_lines(nil), do: []

  defp precomputed_lines(status) do
    ["Precomputed status: #{safe_text(status)}"]
  end

  # -- API-key safe resolution -------------------------------------------------

  defp resolve_api_key(config, context, env_key) do
    config_for_resolver = %{env_key: env_key}

    opts =
      [system_env?: allow_system_env?(context)]
      |> maybe_put_opt(:env, env_map(context))
      |> maybe_put_opt(:api_key, explicit_api_key(context, config))
      |> maybe_put_opt(:app_config, context_value(context, :app_config))

    ApiKey.resolve(config_for_resolver, opts)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp env_map(context) do
    case context_value(context, :env) || context_value(context, :env_map) do
      map when is_map(map) -> map
      _ -> nil
    end
  end

  defp explicit_api_key(context, config) do
    context_value(context, :api_key) || config_field(config, :api_key)
  end

  defp allow_system_env?(context) do
    context
    |> context_value(:auth_status_allow_system_env?)
    |> truthy?()
    |> case do
      true -> true
      false -> truthy?(context_value(context, :allow_system_env?))
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  # -- Provider/config helpers -------------------------------------------------

  defp provider_display(config) do
    id = provider_id(config)
    name = config_field(config, :name)

    cond do
      present_string?(id) and present_string?(name) and to_string(id) != to_string(name) ->
        "#{safe_text(id)} (#{safe_text(name)})"

      present_string?(id) ->
        safe_text(id)

      present_string?(name) ->
        safe_text(name)

      true ->
        "unknown provider"
    end
  end

  defp provider_id(config) do
    config_field(config, :id) || config_field(config, :provider) ||
      config_field(config, :provider_id)
  end

  defp is_fake?(config) do
    config
    |> provider_id()
    |> to_downcased_string()
    |> Kernel.==("fake")
  end

  defp auth_mode(config) do
    (config_field(config, :auth) || config_field(config, :auth_mode) || default_auth_mode(config))
    |> normalize_auth_mode()
  end

  defp default_auth_mode(config) do
    if is_fake?(config), do: :none, else: :unknown
  end

  defp normalize_auth_mode(mode)
       when mode in [:none, :api_key, :bearer_command, :codex_cache, :openai_oauth] do
    mode
  end

  defp normalize_auth_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "none" -> :none
      "api_key" -> :api_key
      "api-key" -> :api_key
      "bearer_command" -> :bearer_command
      "bearer-command" -> :bearer_command
      "codex_cache" -> :codex_cache
      "codex-cache" -> :codex_cache
      "openai_oauth" -> :openai_oauth
      "openai-oauth" -> :openai_oauth
      other -> other
    end
  end

  defp normalize_auth_mode(nil), do: :unknown
  defp normalize_auth_mode(other), do: other

  defp auth_label(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp auth_label(mode), do: safe_text(mode)

  defp env_key(config) do
    case config_field(config, :env_key) do
      key when is_binary(key) and key != "" -> key
      _ -> @default_env_key
    end
  end

  defp config_field(%ProviderConfig{} = config, field), do: Map.get(config, field)

  defp config_field(config, field) when is_map(config) do
    map_get_any(config, [field, Atom.to_string(field)])
  end

  defp config_field(_config, _field), do: nil

  defp missing_source_label(context) do
    cond do
      is_map(env_map(context)) -> "env"
      present_string?(context_value(context, :api_key)) -> "provider_config"
      truthy?(context_value(context, :allow_system_env?)) -> "system_env"
      true -> "not checked (system env disabled)"
    end
  end

  defp credential_source_label(:env), do: "env"
  defp credential_source_label(:provider_config), do: "provider_config"
  defp credential_source_label(:app_config), do: "app_config"
  defp credential_source_label(other), do: auth_label(other)

  defp warnings_line(warnings) when warnings in [nil, []], do: "Warnings: none"

  defp warnings_line(warnings) when is_list(warnings) do
    "Warnings: " <> Enum.map_join(warnings, "; ", &safe_text/1)
  end

  defp warnings_line(warning), do: "Warnings: #{safe_text(warning)}"

  # -- Context/key helpers -----------------------------------------------------

  defp context_value(context, key) when is_atom(key) do
    map_get_any(context, [key, Atom.to_string(key)])
  end

  defp has_context_key?(context, key) do
    Enum.any?([key, Atom.to_string(key)], &Map.has_key?(context, &1))
  end

  defp map_get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key), else: nil
    end)
  end

  defp map_get_any(_map, _keys), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(value), do: not is_nil(value)

  defp to_downcased_string(nil), do: ""

  defp to_downcased_string(value) do
    value
    |> safe_text()
    |> String.downcase()
  end

  # -- Redaction ---------------------------------------------------------------

  defp safe_text(binary) when is_binary(binary), do: safe_binary(binary)
  defp safe_text(atom) when is_atom(atom), do: atom |> Atom.to_string() |> safe_binary()

  defp safe_text(term) do
    term
    |> safe_term()
    |> inspect(limit: :infinity, printable_limit: 500)
    |> safe_binary()
  end

  defp safe_term(%Credential{} = credential), do: Credential.safe_map(credential)

  defp safe_term(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_status_key?(key) do
        {key, @redacted}
      else
        {key, safe_term(value)}
      end
    end)
  end

  defp safe_term(list) when is_list(list), do: Enum.map(list, &safe_term/1)

  defp safe_term(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&safe_term/1)
    |> List.to_tuple()
  end

  defp safe_term(binary) when is_binary(binary), do: safe_binary(binary)
  defp safe_term(term), do: term

  defp safe_binary(binary) do
    binary
    |> redact_codex_paths()
    |> Muse.Prompt.Redactor.redact_text()
  end

  defp redact_codex_paths(binary) do
    Regex.replace(~r/\S*\.codex\/auth\.json/, binary, "~/.codex/auth.json")
  end

  defp sensitive_status_key?(key) do
    normalized =
      key
      |> key_to_string()
      |> String.downcase()
      |> String.replace("-", "_")

    normalized != "redacted" and
      (normalized in [
         "value",
         "raw",
         "raw_value",
         "api_key",
         "authorization",
         "bearer",
         "token",
         "access_token",
         "id_token",
         "refresh_token",
         "stdout",
         "stderr",
         "output",
         "command_output",
         "file_content",
         "contents"
       ] or String.contains?(normalized, "token") or String.contains?(normalized, "secret") or
         String.contains?(normalized, "password"))
  end

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)
end
