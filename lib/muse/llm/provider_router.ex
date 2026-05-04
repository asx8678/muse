defmodule Muse.LLM.ProviderRouter do
  @moduledoc """
  Pure resolver for mapping provider identifiers to provider modules.

  The router is intentionally small and side-effect free: it never starts
  clients, reads environment variables, performs network calls, or creates atoms
  from strings. Runtime code can use it after `Muse.Prompt.ModelPreparer` has
  converted configuration into a provider-neutral `Muse.LLM.Request`.
  """

  alias Muse.LLM.{FakeProvider, OpenAICompatibleProvider, ProviderConfig}

  @type provider_ref :: atom() | String.t() | ProviderConfig.t()
  @type error_reason :: {:unknown_provider, term()}
  @type resolve_result :: {:ok, module()} | {:error, error_reason()}

  @provider_modules %{
    fake: FakeProvider,
    openai_compatible: OpenAICompatibleProvider
  }

  @provider_strings %{
    "fake" => :fake,
    "openai_compatible" => :openai_compatible
  }

  @doc """
  Resolve a provider identifier or config to a provider module.

  Known providers return `{:ok, module}`. Unknown providers return
  `{:error, {:unknown_provider, value}}`, where `value` is the provider id (for
  `%ProviderConfig{}` input) rather than the full config, keeping error terms
  small and safe for logs.

  ## Examples

      iex> Muse.LLM.ProviderRouter.resolve(:fake)
      {:ok, Muse.LLM.FakeProvider}

      iex> Muse.LLM.ProviderRouter.resolve("fake")
      {:ok, Muse.LLM.FakeProvider}

      iex> Muse.LLM.ProviderRouter.resolve("missing")
      {:error, {:unknown_provider, "missing"}}
  """
  @spec resolve(provider_ref() | term()) :: resolve_result()
  def resolve(%ProviderConfig{} = config) do
    config
    |> ProviderConfig.provider_atom()
    |> module_for(config.id)
  end

  def resolve(provider) when is_atom(provider), do: module_for(provider, provider)

  def resolve(provider) when is_binary(provider) do
    provider
    |> provider_atom()
    |> module_for(provider)
  end

  def resolve(provider), do: {:error, {:unknown_provider, provider}}

  defp provider_atom(provider) when is_binary(provider),
    do: Map.get(@provider_strings, provider, :unknown)

  @doc """
  Resolve a provider identifier or raise `ArgumentError` for unknown providers.

  Prefer `resolve/1` at runtime boundaries where provider selection errors should
  be returned to callers. This helper is useful in tests or compile-time wiring
  where raising is acceptable.
  """
  @spec resolve!(provider_ref() | term()) :: module()
  def resolve!(provider) do
    case resolve(provider) do
      {:ok, module} ->
        module

      {:error, {:unknown_provider, unknown}} ->
        raise ArgumentError, "unknown LLM provider: #{inspect(unknown)}"
    end
  end

  defp module_for(provider, _original) when is_map_key(@provider_modules, provider) do
    {:ok, Map.fetch!(@provider_modules, provider)}
  end

  defp module_for(_provider, original), do: {:error, {:unknown_provider, original}}
end
