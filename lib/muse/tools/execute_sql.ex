defmodule Muse.Tools.ExecuteSql do
  @moduledoc """
  Shell tool: execute read-only SQL SELECT queries against the project's
  Ecto database.

  Discovers Ecto repos from the workspace project's app env. Defaults to
  the first configured repo. Uses `Ecto.Adapters.SQL.query/4`. Results are
  capped at 50 rows with a `truncated` flag.

  Mutation queries (INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE) are
  blocked by regex check on the query string.

  ## Output format

      %{
        columns: ["id", "name"],
        rows: [[1, "alice"], [2, "bob"]],
        truncated: false,
        total_rows: 2
      }

  ## Error cases

    * Ecto not available → error: "Ecto is not available"
    * No repos configured → error: "No Ecto repositories configured for this project"
    * Mutation attempted → error: "Only SELECT queries are allowed"
    * SQL syntax error → passthrough DB error message
  """

  alias Muse.Tool.Result

  @compile {:no_warn_undefined, [Ecto.Adapters.SQL, DBConnection.ConnectionError]}

  @tool_name "execute_sql"
  @max_rows 50

  @mutation_pattern ~r/^\s*(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE)\b/i

  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    args
    |> require_query()
    |> reject_mutation()
    |> ensure_ecto_available()
    |> resolve_repo(args, context)
    |> run_query()
  end

  # ---------------------------------------------------------------------------
  # Pipeline steps — each receives {result, query} or a %Result{error}
  # ---------------------------------------------------------------------------

  # Step 1: validate query argument
  defp require_query(%{"query" => query}) when is_binary(query) and query != "" do
    {:ok, query}
  end

  defp require_query(%{"query" => _}) do
    Result.error(@tool_name, "query must be a non-empty string")
  end

  defp require_query(_) do
    Result.error(@tool_name, "query is required")
  end

  # Step 2: reject mutation queries
  defp reject_mutation({:ok, query}) do
    if Regex.match?(@mutation_pattern, query) do
      Result.error(@tool_name, "Only SELECT queries are allowed")
    else
      {:ok, query}
    end
  end

  defp reject_mutation(%Result{} = err), do: err

  # Step 3: ensure Ecto is loaded
  defp ensure_ecto_available({:ok, query}) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL) do
      {:ok, query}
    else
      Result.error(@tool_name, "Ecto is not available")
    end
  end

  defp ensure_ecto_available(%Result{} = err), do: err

  # Step 4: resolve repo
  defp resolve_repo({:ok, query}, args, context) do
    repos = discover_repos(context)

    case {Map.get(args, "repo"), repos} do
      {nil, []} ->
        Result.error(@tool_name, "No Ecto repositories configured for this project")

      {nil, [first | _]} ->
        {:ok, first, query}

      {repo_name, _repos} when is_binary(repo_name) ->
        case parse_repo_module(repo_name) do
          {:ok, mod} ->
            {:ok, mod, query}

          {:error, _} ->
            Result.error(@tool_name, "Invalid repo module name: #{inspect(repo_name)}")
        end
    end
  end

  defp resolve_repo(%Result{} = err, _args, _context), do: err

  # Step 5: run the query
  defp run_query({:ok, repo, query}) do
    case Ecto.Adapters.SQL.query(repo, query, []) do
      {:ok, result} ->
        format_result(result)

      {:error, %{postgres: %{message: msg, code: code}}} ->
        Result.error(@tool_name, "Database error: #{code} — #{msg}")

      {:error, %{message: msg}} ->
        Result.error(@tool_name, "Database error: #{msg}")

      {:error, err} ->
        Result.error(@tool_name, "Database error: #{inspect(err)}")
    end
  rescue
    e in DBConnection.ConnectionError ->
      Result.error(@tool_name, "Connection error: #{Exception.message(e)}")
  end

  defp run_query(%Result{} = err), do: err

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp discover_repos(context) do
    app_name = Map.get(context, :app_name)

    if app_name do
      Application.get_env(app_name, :ecto_repos, [])
    else
      []
    end
  end

  defp parse_repo_module(name) do
    segments =
      name
      |> String.split(".")
      |> Enum.map(&String.to_atom/1)

    {:ok, Module.concat(segments)}
  rescue
    ArgumentError -> {:error, :invalid_module}
  end

  defp format_result(%{columns: columns, rows: rows, num_rows: num_rows}) do
    {capped_rows, truncated?} = cap_rows(rows, @max_rows)

    Result.ok(@tool_name, %{
      columns: columns,
      rows: capped_rows,
      truncated: truncated?,
      total_rows: num_rows
    })
  end

  defp cap_rows(rows, max) when length(rows) <= max do
    {rows, false}
  end

  defp cap_rows(rows, max) do
    {Enum.take(rows, max), true}
  end
end
