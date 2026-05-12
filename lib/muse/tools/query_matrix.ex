defmodule Muse.Tools.QueryMatrix do
  @moduledoc """
  Read-only tool: search the project matrix to find relevant files.

  Queries `Muse.MatrixManager` with search terms and returns a ranked list
  of files with summaries and relevance scores. If the matrix has not been
  indexed yet, automatically triggers indexing.

  ## Output format

      %{
        results: [
          %{path: "lib/foo.ex", summary: "Defines Foo", relevance: 1.8},
          ...
        ],
        total: 5,
        query: "auth logic"
      }
  """

  alias Muse.Tool.Result

  @default_max_results 10

  @doc """
  Execute the query_matrix tool.

  ## Arguments

    * `"query"` — search terms for finding relevant files (required)
    * `"max_results"` — maximum number of results (default: 10)

  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = Map.get(context, :workspace, "")

    with {:ok, query} <- require_query(args),
         {:ok, max_results} <- parse_max_results(args) do
      ensure_indexed(workspace)
      do_query(query, max_results)
    else
      {:error, reason} -> Result.error("query_matrix", reason)
    end
  end

  defp require_query(args) do
    case Map.get(args, "query") do
      nil -> {:error, "query is required"}
      "" -> {:error, "query is required"}
      query when is_binary(query) -> {:ok, query}
      _ -> {:error, "query must be a string"}
    end
  end

  defp parse_max_results(args) do
    case Map.get(args, "max_results") do
      nil ->
        {:ok, @default_max_results}

      n when is_integer(n) and n > 0 ->
        {:ok, min(n, 50)}

      n when is_binary(n) ->
        case Integer.parse(n) do
          {val, ""} when val > 0 -> {:ok, min(val, 50)}
          _ -> {:error, "max_results must be a positive integer"}
        end

      _ ->
        {:error, "max_results must be a positive integer"}
    end
  end

  defp ensure_indexed(workspace) when is_binary(workspace) and workspace != "" do
    case Process.whereis(Muse.MatrixManager) do
      nil ->
        :ok

      _pid ->
        # Trigger indexing if the matrix is empty (soul is blank)
        if Muse.MatrixManager.project_soul() == "" do
          Muse.MatrixManager.index_project(workspace)
        end
    end
  end

  defp ensure_indexed(_), do: :ok

  defp do_query(query, max_results) do
    case Process.whereis(Muse.MatrixManager) do
      nil ->
        Result.error("query_matrix", "matrix manager not available")

      _pid ->
        results =
          Muse.MatrixManager.query(query)
          |> Enum.take(max_results)
          |> Enum.map(fn {path, context, score} ->
            %{path: path, summary: context, relevance: Float.round(score, 2)}
          end)

        Result.ok("query_matrix", %{
          results: results,
          total: length(results),
          query: query
        })
    end
  end
end
