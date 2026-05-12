defmodule Muse.Tools.GetAshResources do
  @moduledoc """
  Read-only tool: list all Ash domains and their resources.

  Uses `Ash.Info.domains_and_resources/1` for each app in the workspace
  to discover domains and their associated resources.

  ## Output format

      %{
        domains: [
          %{domain: "MyApp.Accounts", resources: ["User", "Account"]},
          %{domain: "MyApp.Blog", resources: ["Post", "Comment"]}
        ],
        count: 3
      }

  `count` is the total number of resources across all domains.

  ## Test support

  Accepts `muse_test_domains` in args or context metadata to inject
  deterministic domain lists for testing without live Ash deps.
  When test data is provided, the Ash availability check is bypassed.

  ## Error cases

    * Ash not available → error: "Ash is not available"
    * No domains found → empty list with count 0
  """

  alias Muse.Tool.Result

  @tool_name "get_ash_resources"

  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    case test_domains(args, context) do
      nil ->
        with :ok <- ensure_ash_available() do
          domains = discover_domains()
          total_resources = total_resource_count(domains)
          Result.ok(@tool_name, %{domains: domains, count: total_resources})
        end

      injected ->
        total_resources = total_resource_count(injected)
        Result.ok(@tool_name, %{domains: injected, count: total_resources})
    end
  end

  # ---------------------------------------------------------------------------
  # Ash availability
  # ---------------------------------------------------------------------------

  defp ensure_ash_available do
    if Code.ensure_loaded?(Ash) do
      :ok
    else
      {:error, Result.error(@tool_name, "Ash is not available")}
    end
  end

  # ---------------------------------------------------------------------------
  # Test injection
  # ---------------------------------------------------------------------------

  defp test_domains(args, context) do
    Map.get(args, "muse_test_domains") || Map.get(context, :muse_test_domains)
  end

  # ---------------------------------------------------------------------------
  # Domain discovery
  # ---------------------------------------------------------------------------

  defp discover_domains do
    app_names = discover_app_names()

    for app <- app_names,
        {domain, resources} <- ash_domains_and_resources(app),
        do: build_domain_entry(domain, resources)
  end

  defp discover_app_names do
    # Primary: use the workspace app_name from context if available
    case Application.get_application(__MODULE__) do
      nil -> [Mix.Project.config()[:app] |> to_string()]
      app -> [app]
    end
  rescue
    _ -> []
  end

  defp ash_domains_and_resources(app) do
    try do
      Ash.Info.domains_and_resources(app)
    rescue
      _ -> []
    end
  end

  defp build_domain_entry(domain, resources) do
    %{
      domain: inspect(domain),
      resources: Enum.map(resources, &inspect/1)
    }
  end

  defp total_resource_count(domains) do
    domains
    |> Enum.map(fn d -> length(d.resources) end)
    |> Enum.sum()
  end
end
