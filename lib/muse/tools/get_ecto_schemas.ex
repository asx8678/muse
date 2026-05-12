defmodule Muse.Tools.GetEctoSchemas do
  @moduledoc """
  Read-only tool: list all Ecto schema modules with their file paths.

  Scans compiled project modules for `__changeset__/0` export, then
  cross-references with source location info for file paths. Detects
  Ash resources (via Spark) and flags them.

  ## Output format

      %{
        schemas: [
          %{module: "MyApp.Post", file: "lib/my_app/post.ex", ash_resource?: false},
          %{module: "MyApp.User", file: "lib/my_app/user.ex", ash_resource?: true}
        ],
        count: 2
      }

  ## Test support

  Accepts `muse_test_schemas` in args or context metadata to inject
  deterministic schema lists for testing without live Ecto/Ash deps.
  When test data is provided, the Ecto availability check is bypassed.
  """

  alias Muse.Tool.Result

  @tool_name "get_ecto_schemas"

  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    case test_schemas(args, context) do
      nil ->
        with :ok <- ensure_ecto_available() do
          schemas = discover_schemas()
          Result.ok(@tool_name, %{schemas: schemas, count: length(schemas)})
        end

      injected ->
        Result.ok(@tool_name, %{schemas: injected, count: length(injected)})
    end
  end

  # ---------------------------------------------------------------------------
  # Ecto availability
  # ---------------------------------------------------------------------------

  defp ensure_ecto_available do
    if Code.ensure_loaded?(Ecto) do
      :ok
    else
      {:error, Result.error(@tool_name, "Ecto is not available")}
    end
  end

  # ---------------------------------------------------------------------------
  # Test injection
  # ---------------------------------------------------------------------------

  defp test_schemas(args, context) do
    Map.get(args, "muse_test_schemas") || Map.get(context, :muse_test_schemas)
  end

  # ---------------------------------------------------------------------------
  # Schema discovery
  # ---------------------------------------------------------------------------

  defp discover_schemas do
    for mod <- all_loaded_modules(),
        ecto_schema?(mod),
        do: build_schema_entry(mod)
  end

  defp all_loaded_modules do
    :code.all_loaded()
    |> Enum.map(fn {mod, _} -> mod end)
  end

  defp ecto_schema?(mod) do
    try do
      :erlang.function_exported(mod, :__changeset__, 0)
    rescue
      _ -> false
    end
  end

  defp build_schema_entry(mod) do
    %{
      module: inspect(mod),
      file: source_path(mod),
      ash_resource?: ash_resource?(mod)
    }
  end

  defp source_path(mod) do
    case mod.module_info(:compile) do
      compile when is_list(compile) ->
        case Keyword.get(compile, :source) do
          nil -> nil
          path -> to_string(path)
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp ash_resource?(mod) do
    Code.ensure_loaded?(Spark) and spark_resource?(mod)
  end

  defp spark_resource?(mod) do
    try do
      Code.ensure_loaded?(mod)
      :erlang.function_exported(mod, :__spark_is__, 0)
    rescue
      _ -> false
    end
  end
end
