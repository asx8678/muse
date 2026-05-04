defmodule Muse.Auth.Resolver do
  @moduledoc """
  Single authentication resolution facade for provider requests.

  `resolve/2` accepts a `Muse.LLM.ProviderConfig`, a `Muse.LLM.Request`, a map,
  or a keyword list of provider/request options. It returns one of:

    * `{:ok, %Muse.Auth.Credential{}}` when a credential is resolved
    * `{:error, reason}` when explicitly configured auth cannot be resolved
    * `:none` when auth is explicitly disabled (`auth: :none`) or no auth mode
      is configured

  The `:none` return is intentional: callers can distinguish "no auth needed"
  from "auth configured but failed" without allocating a credential with a nil
  secret value.

  ## Supported auth modes

    * `:none` — no credential
    * `:api_key` — resolves via `Muse.Auth.ApiKey`
    * `:bearer_command` — resolves via `Muse.Auth.BearerCommand` or an injected
      `:auth_runner`
    * `:codex_cache` — resolves via `Muse.Auth.CodexCache`
    * `:openai_oauth` — currently unsupported and returns a clear error

  Codex cache resolution is never attempted silently. It is only used when
  `auth: :codex_cache` is explicit, or when callers opt into fallback behaviour
  with `allow_auth_fallback?: true` and `allow_codex_cache?: true`.

  ## Test/runtime injection

  The facade reads auth-specific fields from either the first argument or `opts`:

    * `:auth_env` / `:env` / `:env_map` — explicit env maps for API keys
    * `:system_env?` — set to `false` to avoid `System.get_env/1`
    * `:auth_runner` — test runner for bearer-command auth
    * `:codex_cache_path` / `:path` — explicit Codex auth cache path
    * `:auth_config` / `:provider_config` — nested config maps/structs

  Error reasons are safe for logs/events: they may mention source labels, env var
  names, or unsupported modes, but never raw token/header values. Credentials are
  returned in memory only and are not persisted.
  """

  alias Muse.Auth.{ApiKey, BearerCommand, CodexCache, Credential}
  alias Muse.EventPayloadRedactor
  alias Muse.LLM.{ProviderConfig, Request}

  @type error_reason :: term()
  @type resolve_result :: {:ok, Credential.t()} | {:error, error_reason()} | :none

  @supported_auth_strings %{
    "none" => :none,
    "api_key" => :api_key,
    "bearer_command" => :bearer_command,
    "codex_cache" => :codex_cache,
    "openai_oauth" => :openai_oauth
  }

  @doc """
  Resolve an auth credential for a provider config, request, or options map.

  See the module documentation for return values and supported injection fields.
  """
  @spec resolve(ProviderConfig.t() | Request.t() | map() | keyword() | nil, keyword()) ::
          resolve_result()
  def resolve(input, opts \\ [])

  def resolve(input, opts) when is_list(opts) do
    context = build_context(input, opts)

    case context |> option_value(:auth) |> normalize_auth_mode() do
      :none ->
        :none

      nil ->
        resolve_fallback(context)

      :api_key ->
        resolve_api_key(context)

      :bearer_command ->
        resolve_bearer_command(context)

      :codex_cache ->
        resolve_codex_cache(context)

      :openai_oauth ->
        {:error,
         {:unsupported_auth_mode, :openai_oauth, "OpenAI OAuth auth is not supported yet"}}

      {:unsupported, mode} ->
        {:error, {:unsupported_auth_mode, safe_auth_mode(mode)}}
    end
  end

  def resolve(_input, _opts), do: {:error, {:invalid_options, "opts must be a keyword list"}}

  # ---------------------------------------------------------------------------
  # Mode-specific resolution
  # ---------------------------------------------------------------------------

  defp resolve_api_key(context) do
    context
    |> api_key_opts()
    |> then(&ApiKey.resolve(context, &1))
  end

  defp resolve_bearer_command(context) do
    command = first_present(context, [:bearer_command, :command])
    runner = option_value(context, :auth_runner)
    source_label = option_value(context, :source_label) || "bearer_command"

    if runner do
      resolve_bearer_with_runner(command, runner, source_label)
    else
      bearer_opts =
        []
        |> put_present(:command, command)
        |> put_present(:source_label, source_label)
        |> put_present(:allow_exec?, bearer_allow_exec?(context))

      BearerCommand.resolve(bearer_opts)
    end
  end

  defp resolve_codex_cache(context) do
    context
    |> codex_cache_opts()
    |> CodexCache.resolve()
  end

  # Default/no-mode behaviour intentionally resolves no credential. Optional
  # fallback is available only when explicitly requested by the caller.
  defp resolve_fallback(context) do
    if truthy?(option_value(context, :allow_auth_fallback?)) do
      case resolve_api_key(context) do
        {:ok, %Credential{}} = ok ->
          ok

        {:error, api_key_reason} = api_key_error ->
          if truthy?(option_value(context, :allow_codex_cache?)) do
            case resolve_codex_cache(context) do
              {:ok, %Credential{}} = ok -> ok
              {:error, _codex_reason} -> api_key_error
            end
          else
            {:error, api_key_reason}
          end
      end
    else
      :none
    end
  end

  # ---------------------------------------------------------------------------
  # API key options
  # ---------------------------------------------------------------------------

  defp api_key_opts(context) do
    []
    |> put_first_present(context, :api_key, [:api_key])
    |> put_first_present(context, :env, [:auth_env, :env])
    |> put_first_present(context, :env_map, [:env_map])
    |> put_app_config(context)
    |> put_first_present(context, :system_env?, [:system_env?])
  end

  defp put_app_config(opts, context) do
    case first_present(context, [:app_config]) do
      nil -> opts
      app_config -> put_present(opts, :app_config, normalize_app_config(app_config))
    end
  end

  defp normalize_app_config(app_config) when is_list(app_config), do: app_config

  defp normalize_app_config(app_config) when is_map(app_config) do
    case option_value(app_config, :api_key) do
      nil -> []
      value -> [api_key: value]
    end
  end

  defp normalize_app_config(_app_config), do: []

  # ---------------------------------------------------------------------------
  # Bearer command runner support
  # ---------------------------------------------------------------------------

  defp bearer_allow_exec?(context) do
    first_present(context, [:allow_exec?, :bearer_command_allow_exec?]) || false
  end

  defp resolve_bearer_with_runner(nil, _runner, source_label),
    do: {:error, {:no_command, source_label}}

  defp resolve_bearer_with_runner(command, runner, source_label) when is_function(runner, 1) do
    runner
    |> safe_run(fn -> runner.(command) end)
    |> normalize_runner_result(source_label)
  end

  defp resolve_bearer_with_runner(command, runner, source_label) when is_function(runner, 2) do
    runner
    |> safe_run(fn -> runner.(command, source_label: source_label) end)
    |> normalize_runner_result(source_label)
  end

  defp resolve_bearer_with_runner(_command, _runner, _source_label) do
    {:error, {:invalid_runner, "auth_runner must be a one- or two-arity function"}}
  end

  defp safe_run(_runner, fun) do
    {:ok, fun.()}
  rescue
    _exception -> {:error, {:exec_failed, "auth_runner raised"}}
  catch
    _kind, _reason -> {:error, {:exec_failed, "auth_runner failed"}}
  end

  defp normalize_runner_result({:ok, {:ok, output}}, source_label),
    do: output_to_credential(output, source_label)

  defp normalize_runner_result({:ok, {output, 0}}, source_label),
    do: output_to_credential(output, source_label)

  defp normalize_runner_result({:ok, output}, source_label) when is_binary(output),
    do: output_to_credential(output, source_label)

  defp normalize_runner_result({:ok, {:error, _reason}}, _source_label),
    do: {:error, {:exec_failed, "auth_runner failed"}}

  defp normalize_runner_result({:ok, {_output, exit_status}}, _source_label)
       when is_integer(exit_status),
       do: {:error, {:exec_failed, "auth_runner exited with non-zero status"}}

  defp normalize_runner_result({:error, reason}, _source_label), do: {:error, reason}

  defp normalize_runner_result(_other, _source_label),
    do: {:error, {:exec_failed, "auth_runner returned an unsupported result"}}

  defp output_to_credential(output, source_label) when is_binary(output) do
    token = String.trim_trailing(output)

    if token == "" do
      {:error, :empty_output}
    else
      {:ok,
       %Credential{
         type: :bearer,
         value: token,
         source: :command,
         source_ref: source_label,
         redacted: Credential.redact_value(token)
       }}
    end
  end

  defp output_to_credential(_output, _source_label), do: {:error, :empty_output}

  # ---------------------------------------------------------------------------
  # Codex cache options
  # ---------------------------------------------------------------------------

  defp codex_cache_opts(context) do
    []
    |> put_first_present(context, :path, [:codex_cache_path, :path])
    |> put_first_present(context, :home, [:codex_cache_home, :home])
  end

  # ---------------------------------------------------------------------------
  # Context normalization
  # ---------------------------------------------------------------------------

  defp build_context(input, opts) do
    input_map = input_to_map(input)
    opts_map = input_to_map(opts)

    %{}
    |> merge_present(nested_map(input_map, :provider_config))
    |> merge_present(strip_nested_config(input_map))
    |> merge_present(nested_map(input_map, :auth_config))
    |> merge_present(nested_map(opts_map, :provider_config))
    |> merge_present(nested_map(opts_map, :auth_config))
    |> merge_present(strip_nested_config(opts_map))
  end

  defp input_to_map(nil), do: %{}

  defp input_to_map(%Request{options: options} = request) do
    options = if is_map(options), do: options, else: %{}

    options
    |> Map.put_new(:provider, request.provider)
    |> Map.put_new(:wire_api, request.wire_api)
    |> Map.put_new(:transport, request.transport)
  end

  defp input_to_map(%ProviderConfig{} = config), do: Map.from_struct(config)

  defp input_to_map(%{__struct__: _struct} = struct), do: Map.from_struct(struct)
  defp input_to_map(map) when is_map(map), do: map
  defp input_to_map(list) when is_list(list), do: Map.new(list)
  defp input_to_map(_other), do: %{}

  defp nested_map(map, key) do
    case option_value(map, key) do
      nil -> %{}
      value -> input_to_map(value)
    end
  end

  defp strip_nested_config(map) when is_map(map) do
    Map.drop(map, [:provider_config, "provider_config", :auth_config, "auth_config"])
  end

  defp merge_present(left, right) when is_map(right) do
    Enum.reduce(right, left, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  # ---------------------------------------------------------------------------
  # Auth mode normalization and safe values
  # ---------------------------------------------------------------------------

  defp normalize_auth_mode(nil), do: nil

  defp normalize_auth_mode(mode)
       when mode in [:none, :api_key, :bearer_command, :codex_cache, :openai_oauth],
       do: mode

  defp normalize_auth_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> String.downcase()
    |> then(fn
      "" -> nil
      value -> Map.get(@supported_auth_strings, value, {:unsupported, mode})
    end)
  end

  defp normalize_auth_mode(mode), do: {:unsupported, mode}

  defp safe_auth_mode(mode) when is_atom(mode), do: mode

  defp safe_auth_mode(mode) when is_binary(mode) do
    mode
    |> EventPayloadRedactor.redact_string()
    |> String.slice(0, 80)
  end

  defp safe_auth_mode(mode) do
    mode
    |> inspect(limit: 5, printable_limit: 80)
    |> EventPayloadRedactor.redact_string()
    |> String.slice(0, 80)
  end

  # ---------------------------------------------------------------------------
  # Generic option helpers
  # ---------------------------------------------------------------------------

  defp put_first_present(opts, context, target_key, source_keys) do
    put_present(opts, target_key, first_present(context, source_keys))
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp first_present(context, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case fetch_option(context, key) do
        {:ok, nil} -> {:cont, nil}
        {:ok, value} -> {:halt, {:found, value}}
        :error -> {:cont, nil}
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  defp option_value(map, key) do
    case fetch_option(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_option(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, string_key) -> {:ok, Map.fetch!(map, string_key)}
      true -> :error
    end
  end

  defp fetch_option(map, key) when is_map(map) do
    if Map.has_key?(map, key), do: {:ok, Map.fetch!(map, key)}, else: :error
  end

  defp fetch_option(_map, _key), do: :error

  defp truthy?(value), do: value not in [nil, false]
end
