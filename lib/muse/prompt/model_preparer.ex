defmodule Muse.Prompt.ModelPreparer do
  @moduledoc """
  Converts a `Muse.Prompt.Bundle` into a `Muse.LLM.Request` for provider dispatch.

  The ModelPreparer is the bridge between the prompt assembly system and
  the LLM provider interface. It takes the assembled bundle and provider
  configuration, and produces a provider-ready request struct.

  ## Responsibilities

    * Convert bundle messages to `Muse.LLM.Request` messages
    * Map bundle fields to request fields (model, tools, response_format, etc.)
    * Apply provider-specific options (wire_api, transport, etc.)
    * Validate locally even when providers claim schema validation

  ## API

    * `to_request(bundle, provider_config_or_opts, opts \\ [])` → `%Muse.LLM.Request{}`
  """

  alias Muse.LLM.Request
  alias Muse.Prompt.Bundle

  @doc """
  Convert a prompt bundle to a `Muse.LLM.Request` struct.

  The `provider_config_or_opts` can be either a `Muse.LLM.ProviderConfig`
  struct or a keyword list of provider options.

  ## Options

    * `:wire_api`    — `:responses` | `:chat_completions` | `nil`
    * `:transport`  — `:none` | `:sse` | `:websocket` | `nil`
    * `:stream`      — whether to request streaming (default `true`)
    * `:tool_choice` — `:auto` | `:none` | `:required` | `{:function, name}` | `nil`
    * `:temperature` — float override
    * `:max_tokens`  — max output tokens
    * `:store`       — whether the provider should persist the response
    * `:response_format` — structured output format when the bundle has none
    * `:previous_response_id` — provider conversation continuity token

  ## Examples

      iex> bundle = Muse.Prompt.Assembler.build(session, profile, "hello")
      iex> request = Muse.Prompt.ModelPreparer.to_request(bundle, [])
      iex> %Muse.LLM.Request{} = request
      iex> request.messages |> length() > 0
      true
  """
  @spec to_request(Bundle.t(), map() | keyword(), keyword()) :: Request.t()
  def to_request(bundle, provider_config_or_opts, opts \\ [])

  def to_request(bundle, %Muse.LLM.ProviderConfig{} = provider_config, opts) do
    provider = opts[:provider] || Muse.LLM.ProviderConfig.provider_atom(provider_config)
    provider_map = Map.from_struct(provider_config) |> Map.put(:provider, provider)
    build_request(bundle, provider_map, opts)
  end

  def to_request(bundle, %{__struct__: _} = provider_config, opts) do
    build_request(bundle, Map.from_struct(provider_config), opts)
  end

  def to_request(bundle, provider_config_or_opts, opts) when is_map(provider_config_or_opts) do
    build_request(bundle, provider_config_or_opts, opts)
  end

  def to_request(bundle, provider_config_or_opts, opts) when is_list(provider_config_or_opts) do
    build_request(bundle, Map.new(provider_config_or_opts), opts)
  end

  # -- Private ------------------------------------------------------------------

  defp build_request(bundle, provider_map, opts) do
    provider = opts[:provider] || provider_map[:provider]
    wire_api = opts[:wire_api] || provider_map[:wire_api]
    transport = opts[:transport] || provider_map[:transport]
    model = opts[:model] || bundle.model || provider_map[:model]

    %Request{
      provider: provider,
      model: model,
      wire_api: wire_api,
      transport: transport,
      session_id: bundle.session_id,
      turn_id: bundle.turn_id,
      messages: bundle.messages,
      prompt_bundle: bundle,
      tools: bundle.tools,
      tool_choice: option_or_config(opts, provider_map, :tool_choice),
      previous_response_id: option_or_config(opts, provider_map, :previous_response_id),
      stream: Keyword.get(opts, :stream, true),
      store: option_or_config(opts, provider_map, :store),
      temperature: option_or_config(opts, provider_map, :temperature),
      max_tokens: option_or_config(opts, provider_map, :max_tokens),
      response_format: bundle.response_format || option_or_config(opts, provider_map, :response_format),
      metadata: %{
        bundle_id: bundle.id,
        muse_id: bundle.muse_id,
        created_at: bundle.created_at
      },
      options: Map.drop(provider_map, [:provider, :wire_api, :transport])
    }
  end

  defp option_or_config(opts, provider_map, key, default \\ nil) do
    if Keyword.has_key?(opts, key) do
      Keyword.fetch!(opts, key)
    else
      Map.get(provider_map, key, default)
    end
  end
end
