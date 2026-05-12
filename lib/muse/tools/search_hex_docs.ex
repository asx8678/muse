defmodule Muse.Tools.SearchHexDocs do
  @moduledoc """
  Network tool: search hexdocs.pm filtered to the project's exact dependency versions.

  Queries the hexdocs.pm Typesense-powered search API and, when available, filters
  results to only include packages matching the project's locked dependencies. This
  ensures documentation matches the exact versions in use.

  ## Output format

      %{
        results: [
          %{
            package: "phoenix",
            version: "1.8.7",
            title: "Phoenix.Endpoint",
            type: "behaviour",
            excerpt: "Defines a Phoenix endpoint...",
            url: "https://hexdocs.pm/phoenix/1.8.7/Phoenix.Endpoint.html"
          }
        ],
        total: 5,
        query: "endpoint"
      }

  ## Edge cases

    * No `mix.lock` found — search without version filtering
    * Network timeout — informative error
    * Empty results — clear message
    * Req not available — error: "Req HTTP client is not available"
  """

  alias Muse.Tool.Result

  @search_url "https://search.hexdocs.pm/multi_search"
  @default_timeout 15_000
  @max_results 20
  @per_page 50

  @doc """
  Execute the search_hex_docs tool.

  ## Arguments

    * `"query"` — search terms for hexdocs.pm (required)
    * `"packages"` — optional list of package names to limit search to

  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    with {:ok, query} <- require_query(args),
         :ok <- ensure_req_available() do
      workspace = Map.get(context, :workspace, "")
      packages = Map.get(args, "packages")
      deps = parse_mix_lock(workspace)

      do_search(query, packages, deps)
    else
      {:error, reason} ->
        Result.error("search_hex_docs", reason)
    end
  end

  # -- Validation ---------------------------------------------------------------

  defp require_query(args) do
    case Map.get(args, "query") do
      nil -> {:error, "query is required"}
      "" -> {:error, "query is required"}
      query when is_binary(query) -> {:ok, query}
      _ -> {:error, "query must be a string"}
    end
  end

  defp ensure_req_available do
    if Code.ensure_loaded?(Req) do
      :ok
    else
      {:error, "Req HTTP client is not available"}
    end
  end

  # -- mix.lock parsing ---------------------------------------------------------

  @doc """
  Parse `mix.lock` to extract package names and versions.

  Returns a map of `%{package_name => version_string}`.
  Returns an empty map if the file cannot be read or parsed.
  """
  @spec parse_mix_lock(String.t()) :: %{String.t() => String.t()}
  def parse_mix_lock(workspace) when is_binary(workspace) and workspace != "" do
    lock_path = Path.join(workspace, "mix.lock")

    with {:ok, content} <- File.read(lock_path),
         {%{} = lock_map, _binding} <- Code.eval_string(content) do
      extract_deps(lock_map)
    else
      _ -> %{}
    end
  end

  def parse_mix_lock(_), do: %{}

  defp extract_deps(lock_map) do
    lock_map
    |> Enum.flat_map(fn
      # Mix.lock v2 format (8-tuple with outer checksum)
      {name,
       {:hex, _lib_name, version, _inner_checksum, _build_tools, _deps, _repo, _outer_checksum}} ->
        [{to_string(name), version}]

      # Mix.lock v1 format (7-tuple)
      {name, {:hex, _lib_name, version, _hash, _deps, _hexpm_hash, _source_hash}} ->
        [{to_string(name), version}]

      # Mix.lock legacy format (6-tuple)
      {name, {:hex, _lib_name, version, _hash, _deps, _hexpm_hash}} ->
        [{to_string(name), version}]

      _ ->
        []
    end)
    |> Map.new()
  end

  # -- Search -------------------------------------------------------------------

  defp do_search(query, packages_filter, deps) do
    search_params = build_search_params(query, packages_filter, deps)

    case http_post(search_params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        results = parse_response(body)

        Result.ok("search_hex_docs", %{
          results: results,
          total: length(results),
          query: query
        })

      {:ok, %Req.Response{status: status}} ->
        Result.error("search_hex_docs", "hexdocs.pm returned HTTP #{status}")

      {:error, exception} ->
        Result.error("search_hex_docs", "network error: #{Exception.message(exception)}")
    end
  rescue
    e ->
      Result.error("search_hex_docs", "search failed: #{Exception.message(e)}")
  end

  defp build_search_params(query, packages_filter, deps) do
    filter_by = build_filter_by(deps, packages_filter)

    base = %{
      "q" => query,
      "query_by" => "title,doc",
      "query_by_weights" => "3,1",
      "page" => 1,
      "per_page" => @per_page,
      "highlight_fields" => "none"
    }

    params = if filter_by, do: Map.put(base, "filter_by", filter_by), else: base

    %{"searches" => [params]}
  end

  defp build_filter_by(deps, _packages_filter) when map_size(deps) == 0, do: nil

  defp build_filter_by(deps, packages_filter) do
    filtered = maybe_filter_packages(deps, packages_filter)

    case filtered do
      [] ->
        nil

      _ ->
        entries =
          filtered
          |> Enum.map(fn {name, version} -> "`#{name}-#{version}`" end)
          |> Enum.join(",")

        "package:=[#{entries}]"
    end
  end

  defp maybe_filter_packages(deps, nil), do: Map.to_list(deps)

  defp maybe_filter_packages(deps, packages) when is_list(packages) do
    package_set = MapSet.new(packages, &to_string/1)
    Enum.filter(deps, fn {name, _version} -> MapSet.member?(package_set, name) end)
  end

  defp maybe_filter_packages(deps, _), do: Map.to_list(deps)

  defp http_post(body) do
    Req.post(@search_url,
      json: body,
      receive_timeout: @default_timeout,
      connect_options: [timeout: @default_timeout]
    )
  end

  # -- Response parsing ---------------------------------------------------------

  defp parse_response(body) do
    case body do
      %{"results" => [%{"hits" => hits} | _]} when is_list(hits) ->
        hits
        |> Enum.take(@max_results)
        |> Enum.map(&format_result/1)

      _ ->
        []
    end
  end

  defp format_result(%{"document" => doc}) do
    package = Map.get(doc, "package", "")
    {pkg_name, version} = split_package(package)
    ref = Map.get(doc, "ref", "")
    url = build_url(pkg_name, version, ref)

    %{
      package: pkg_name,
      version: version,
      title: Map.get(doc, "title", ""),
      type: Map.get(doc, "type", ""),
      excerpt: truncate_excerpt(Map.get(doc, "doc", "")),
      url: url
    }
  end

  defp format_result(_), do: %{}

  defp split_package(package) do
    case String.split(package, "-", parts: 2) do
      [name, version] -> {name, version}
      [name] -> {name, nil}
      [] -> {"", nil}
    end
  end

  defp build_url(pkg_name, version, ref) do
    base = "https://hexdocs.pm/#{pkg_name}"

    case {version, ref} do
      {nil, ""} -> base
      {nil, ref} -> "#{base}/#{ref}"
      {version, ""} -> "#{base}/#{version}"
      {version, ref} -> "#{base}/#{version}/#{ref}"
    end
  end

  defp truncate_excerpt(doc) when byte_size(doc) > 300 do
    String.slice(doc, 0, 300) <> "..."
  end

  defp truncate_excerpt(doc), do: doc
end
