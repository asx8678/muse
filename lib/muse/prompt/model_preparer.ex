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
    * For Planning Muse (`response_mode: :plan`, `output_schema: Muse.Plan`):
      - Filter tools to read-only only from the profile (no write/shell/network)
      - Attach `Muse.PlanSchema.schema/0` as `response_format` when no explicit format set
      - Include `response_mode` in request metadata

  ## API

    * `to_request(bundle, provider_config_or_opts, opts \\ [])` → `%Muse.LLM.Request{}`
  """

  alias Muse.LLM.Request
  alias Muse.Prompt.Bundle
  alias Muse.Tool.Registry, as: ToolRegistry

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

    # Read response_mode and output_schema from bundle metadata (populated by
    # the Assembler from the Muse profile). This avoids a registry lookup and
    # correctly handles test profiles that may differ from the registry.
    response_mode = bundle.metadata[:response_mode]
    output_schema = bundle.metadata[:output_schema]

    # For Planning Muse (response_mode: :plan, output_schema: Muse.Plan),
    # enforce read-only tools and attach a structured response schema hint.
    {tools, response_format} =
      planning_muse_request_overrides(response_mode, output_schema, bundle, opts, provider_map)

    # When the provider does not support tool/function calling
    # (supports_tools: false), omit tools and tool_choice from the request.
    # Providers like wafer.ai / GLM-5.1 that receive tools/tool_choice but
    # return textual tool-call markers instead of structured tool_calls
    # cause Muse to stall — the text appears as assistant content but tools
    # are never actually invoked.
    {tools, tool_choice} =
      if provider_supports_tools?(provider_map) do
        {tools, option_or_config(opts, provider_map, :tool_choice)}
      else
        {[], :none}
      end

    %Request{
      provider: provider,
      model: model,
      wire_api: wire_api,
      transport: transport,
      session_id: bundle.session_id,
      turn_id: bundle.turn_id,
      messages: bundle.messages,
      prompt_bundle: bundle,
      tools: tools,
      tool_choice: tool_choice,
      previous_response_id: option_or_config(opts, provider_map, :previous_response_id),
      stream: Keyword.get(opts, :stream, true),
      store: option_or_config(opts, provider_map, :store),
      temperature: option_or_config(opts, provider_map, :temperature),
      max_tokens: option_or_config(opts, provider_map, :max_tokens),
      response_format: response_format,
      metadata: %{
        bundle_id: bundle.id,
        muse_id: bundle.muse_id,
        created_at: bundle.created_at,
        response_mode: response_mode
      },
      options: Map.drop(provider_map, [:provider, :wire_api, :transport])
    }
  end

  # When the active muse has response_mode: :plan and output_schema referencing
  # Muse.Plan, filter tools to read-only only from the bundle and attach a
  # structured JSON response format hint derived from Muse.PlanSchema.
  #
  # When the provider does not support structured outputs
  # (supports_structured_outputs: false), omit the response_format to avoid
  # sending an unsupported json_schema response_format to providers like
  # wafer.ai / GLM-5.1 that return empty content when strict structured
  # outputs are requested. The prompt instructions already ask the model to
  # return JSON, so the PlanParser can still handle plain JSON content.
  defp planning_muse_request_overrides(:plan, Muse.Plan, bundle, opts, provider_map) do
    # Filter tools from the bundle: only keep those that are known, non-blocked tools
    # (read-only enforcement). The Assembler already excluded blocked tools from
    # the profile's tool list, but we double-check here as a safety layer.
    read_only_tools =
      bundle.tools
      |> Enum.filter(fn tool_spec ->
        name = tool_spec[:name] || tool_spec["function"]["name"]

        is_binary(name) and not ToolRegistry.blocked_tool?(name) and
          ToolRegistry.known_tool?(name)
      end)

    plan_response_format =
      if provider_supports_structured_outputs?(provider_map) do
        # Use PlanSchema as the response_format hint unless the caller already set one
        bundle.response_format ||
          option_or_config(opts, provider_map, :response_format) ||
          Muse.PlanSchema.schema()
      else
        # Provider doesn't support strict structured outputs — omit response_format
        # entirely. Prompt instructions still request JSON format.
        bundle.response_format ||
          option_or_config(opts, provider_map, :response_format)
      end

    {read_only_tools, plan_response_format}
  end

  # For all other muse profiles, use bundle tools and standard response_format
  # When the active muse has response_mode: :patch (Coding Muse), filter
  # tools to read-only plus patch_propose only. patch_apply, rollback_checkpoint,
  # and test_runner are excluded — Coding Muse can propose patches but must not
  # autonomously apply them, roll back, or run test commands during patch
  # proposal mode. These tools require separate post-approval paths.
  # No PlanSchema response_format for Coding Muse.
  @coding_excluded_tools MapSet.new(["patch_apply", "rollback_checkpoint", "test_runner"])

  defp planning_muse_request_overrides(:patch, _output_schema, bundle, opts, provider_map) do
    coding_tools =
      bundle.tools
      |> Enum.filter(fn tool_spec ->
        name = tool_spec[:name] || tool_spec["function"]["name"]

        is_binary(name) and
          not ToolRegistry.blocked_tool?(name) and
          not MapSet.member?(@coding_excluded_tools, name) and
          (ToolRegistry.known_tool?(name) or name == "patch_propose")
      end)

    response_format =
      bundle.response_format || option_or_config(opts, provider_map, :response_format)

    {coding_tools, response_format}
  end

  # For all other muse profiles, use bundle tools and standard response_format
  defp planning_muse_request_overrides(_response_mode, _output_schema, bundle, opts, provider_map) do
    response_format =
      bundle.response_format || option_or_config(opts, provider_map, :response_format)

    {bundle.tools, response_format}
  end

  defp option_or_config(opts, provider_map, key, default \\ nil) do
    if Keyword.has_key?(opts, key) do
      Keyword.fetch!(opts, key)
    else
      Map.get(provider_map, key, default)
    end
  end

  # Check whether the provider supports OpenAI strict structured outputs
  # (response_format with type: json_schema). Defaults to true for backward
  # compatibility — providers that haven't set the flag are assumed to support
  # structured outputs. Providers like wafer.ai that don't support it should
  # set MUSE_STRUCTURED_OUTPUTS=false or set supports_structured_outputs: false
  # in their ProviderConfig.
  defp provider_supports_structured_outputs?(provider_map) do
    case Map.get(provider_map, :supports_structured_outputs) do
      nil -> true
      false -> false
      true -> true
    end
  end

  # Check whether the provider supports OpenAI-style tool/function calling.
  # Defaults to true for backward compatibility — providers that haven't set
  # the flag are assumed to support tools. Providers like wafer.ai / GLM-5.1
  # that receive tools/tool_choice but return textual tool-call markers
  # instead of structured tool_calls should set MUSE_TOOLS=false or
  # supports_tools: false in their ProviderConfig.
  defp provider_supports_tools?(provider_map) do
    case Map.get(provider_map, :supports_tools) do
      nil -> true
      false -> false
      true -> true
    end
  end
end
