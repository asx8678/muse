defmodule Muse.Tools.GetSourceLocation do
  @moduledoc """
  Read-only tool: resolve `Module.function/arity` → `file:line`
  via BEAM bytecode introspection.

  Input: `reference` (string, required) — `Module`, `Module.function`,
  or `Module.function/arity`

  Supports `dep:PackageName` for dependency root lookup via
  `Mix.Project.deps_paths/0`.

  Output: `%{path: String.t(), line: integer(), source: String.t()}` or error.
  """

  alias Muse.Tool.Result

  @tool_name "get_source_location"

  @spec execute(map(), map()) :: Result.t()
  def execute(%{"reference" => reference}, context) when is_binary(reference) do
    workspace = Map.get(context, :workspace, File.cwd!())

    cond do
      String.starts_with?(reference, "dep:") ->
        resolve_dep(reference, workspace)

      true ->
        resolve_reference(reference, workspace)
    end
  end

  def execute(_args, _context) do
    Result.error(@tool_name, "Missing required argument: reference")
  end

  # ---------------------------------------------------------------------------
  # Dep resolution
  # ---------------------------------------------------------------------------

  defp resolve_dep(reference, workspace) do
    package =
      reference
      |> String.trim_leading("dep:")
      |> String.trim()

    deps_paths = Mix.Project.deps_paths()

    case Map.get(deps_paths, String.to_atom(package)) do
      nil ->
        Result.error(@tool_name, "Dependency '#{package}' not found in project")

      path ->
        rel = relative_path(to_string(path), workspace)
        Result.ok(@tool_name, %{path: rel, line: 1, source: "dep:#{package}"})
    end
  end

  # ---------------------------------------------------------------------------
  # Reference resolution
  # ---------------------------------------------------------------------------

  defp resolve_reference(reference, workspace) do
    with {:ok, parsed} <- parse_reference(reference),
         {:ok, module} <- ensure_module_loaded(parsed.module) do
      case parsed do
        %{function: nil} ->
          module_result(module, workspace)

        %{function: func, arity: nil} ->
          function_result(module, func, nil, workspace)

        %{function: func, arity: arity} ->
          function_result(module, func, arity, workspace)
      end
    else
      {:error, message} ->
        Result.error(@tool_name, message)
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  defp parse_reference(reference) do
    case Code.string_to_quoted(reference, file: "reference") do
      {:ok, ast} ->
        extract_from_ast(ast)

      {:error, {line, error, token}} ->
        {:error,
         "Invalid reference '#{reference}': #{inspect(error)} at line #{line}, token: #{inspect(token)}"}
    end
  end

  # Module only: {:__aliases__, _, [:Muse, :Tool, :Result]}
  defp extract_from_ast({:__aliases__, _, segments}) when is_list(segments) do
    {:ok, %{module: Module.concat(segments), function: nil, arity: nil}}
  end

  # Module.function: {{:., _, [{:__aliases__, _, segments}, func]}, _, []}
  defp extract_from_ast({{:., _, [{:__aliases__, _, segments}, func]}, _, []})
       when is_list(segments) and is_atom(func) do
    {:ok, %{module: Module.concat(segments), function: func, arity: nil}}
  end

  # Module.function/arity: {:/, _, [call_ast, arity]}
  defp extract_from_ast({:/, _, [call_ast, arity]}) when is_integer(arity) do
    case call_ast do
      {{:., _, [{:__aliases__, _, segments}, func]}, _, []}
      when is_list(segments) and is_atom(func) ->
        {:ok, %{module: Module.concat(segments), function: func, arity: arity}}

      _ ->
        {:error, "Invalid function/arity reference"}
    end
  end

  defp extract_from_ast(_ast) do
    {:error,
     "Could not parse reference — expected Module, Module.function, or Module.function/arity"}
  end

  # ---------------------------------------------------------------------------
  # Module loading
  # ---------------------------------------------------------------------------

  defp ensure_module_loaded(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        {:ok, module}

      {:error, reason} ->
        {:error, "Module #{inspect(module)} not found (#{inspect(reason)})"}
    end
  end

  # ---------------------------------------------------------------------------
  # Module-level resolution
  # ---------------------------------------------------------------------------

  defp module_result(module, workspace) do
    source_path = get_module_source(module)

    cond do
      source_path != nil and file_exists?(source_path) ->
        rel = relative_path(to_string(source_path), workspace)
        Result.ok(@tool_name, %{path: rel, line: 1, source: inspect(module)})

      source_path != nil and core_source_path?(source_path) ->
        Result.error(
          @tool_name,
          "Core Elixir/OTP module #{inspect(module)}: source not available locally " <>
            "(compiled at #{source_path})"
        )

      source_path != nil ->
        rel = relative_path(to_string(source_path), workspace)
        Result.ok(@tool_name, %{path: rel, line: 1, source: inspect(module)})

      true ->
        Result.error(@tool_name, "No source information available for #{inspect(module)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Function-level resolution
  # ---------------------------------------------------------------------------

  defp function_result(module, function, arity, workspace) do
    source_path = get_module_source(module)
    line = find_function_line(module, function, arity)

    cond do
      source_path != nil and file_exists?(source_path) and line != nil ->
        rel = relative_path(to_string(source_path), workspace)
        source_label = format_source_label(module, function, arity)
        Result.ok(@tool_name, %{path: rel, line: line, source: source_label})

      source_path != nil and file_exists?(source_path) and line == nil ->
        # Function not found — return module location with function reference in source
        rel = relative_path(to_string(source_path), workspace)
        source_label = format_source_label(module, function, arity)
        Result.ok(@tool_name, %{path: rel, line: 1, source: source_label})

      source_path != nil and core_source_path?(source_path) ->
        Result.error(
          @tool_name,
          "Core Elixir/OTP module #{inspect(module)}: source not available locally"
        )

      source_path != nil and line != nil ->
        rel = relative_path(to_string(source_path), workspace)
        source_label = format_source_label(module, function, arity)
        Result.ok(@tool_name, %{path: rel, line: line, source: source_label})

      true ->
        Result.error(
          @tool_name,
          "No source information for #{inspect(module)}.#{function}/#{arity || "?"}"
        )
    end
  end

  defp format_source_label(module, function, nil) do
    "#{inspect(module)}.#{function}"
  end

  defp format_source_label(module, function, arity) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  # ---------------------------------------------------------------------------
  # Function line lookup
  # ---------------------------------------------------------------------------

  defp find_function_line(module, function, arity) do
    with nil <- find_line_from_abstract_code(module, function, arity),
         nil <- find_line_from_docs(module, function, arity) do
      nil
    end
  end

  defp find_line_from_abstract_code(module, function, arity) do
    beam_path = :code.which(module)

    if is_list(beam_path) and File.exists?(to_string(beam_path)) do
      case :beam_lib.chunks(beam_path, [:abstract_code]) do
        {:ok, {^module, [{:abstract_code, {_version, abstract_code}}]}} ->
          find_function_in_abstract(abstract_code, function, arity)

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp find_function_in_abstract(abstract_code, function, arity) do
    matching =
      for {:function, anno, name, func_arity, _clauses} <- abstract_code,
          name == function,
          arity == nil or func_arity == arity,
          line = extract_line(anno),
          line != nil,
          do: line

    case matching do
      [] -> nil
      lines -> Enum.min(lines)
    end
  rescue
    _ -> nil
  end

  # erl_anno can be an integer or {line, column} tuple
  defp extract_line({line, _col}) when is_integer(line), do: line
  defp extract_line(line) when is_integer(line), do: line
  defp extract_line(_), do: nil

  defp find_line_from_docs(module, function, arity) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _beam_lang, _format, _module_doc, _metadata, docs} ->
        matching =
          for {{kind, name, func_arity}, line, _sig, _doc, _meta} <- docs,
              kind in [:function, :macro],
              name == function,
              is_integer(line) and line > 0,
              arity == nil or func_arity == arity,
              do: line

        case matching do
          [] -> nil
          lines -> Enum.min(lines)
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp get_module_source(module) do
    case module.module_info(:compile) do
      compile when is_list(compile) ->
        Keyword.get(compile, :source)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp core_source_path?(path) do
    path_str = to_string(path)

    String.contains?(path_str, "/elixir/lib/") or
      String.contains?(path_str, "/erlang/") or
      String.contains?(path_str, "/otp/")
  end

  defp file_exists?(path) do
    File.exists?(to_string(path))
  end

  defp relative_path(path, workspace) do
    path_str = to_string(path)
    workspace_str = to_string(workspace)

    # Ensure workspace doesn't have trailing slash for consistent prefix matching
    workspace_prefix = String.trim_trailing(workspace_str, "/")

    if String.starts_with?(path_str, workspace_prefix <> "/") do
      String.trim_leading(path_str, workspace_prefix <> "/")
    else
      path_str
    end
  end
end
