defmodule Muse.Tools.GetDocs do
  @moduledoc """
  Read-only tool: fetch formatted Markdown documentation for Elixir modules,
  functions, and callbacks.

  Supports references:

    - `Module` — module documentation with function summaries
    - `Module.function` — documentation for all arities of a function
    - `Module.function/arity` — documentation for a specific function/arity
    - `c:Module.callback/arity` — documentation for a callback
    - `:erlang_module` — Erlang module documentation
    - `:erlang_module.function/arity` — Erlang function documentation

  Uses `Code.fetch_docs/1` to retrieve documentation and formats output as
  readable Markdown with type signatures.

  ## Output

      %{
        reference: "Enum.map/2",
        markdown: "# Enum.map/2\n\n..."
      }
  """

  alias Muse.Tool.Result

  @spec execute(map(), map()) :: Result.t()
  def execute(args, _context) do
    with {:ok, reference} <- require_reference(args),
         {:ok, parsed} <- parse_reference(reference),
         {:ok, markdown} <- fetch_and_format(parsed) do
      Result.ok("get_docs", %{reference: reference, markdown: markdown})
    else
      {:error, reason} -> Result.error("get_docs", reason)
    end
  end

  # -- Argument validation ------------------------------------------------------

  defp require_reference(%{"reference" => ref}) when is_binary(ref) and ref != "",
    do: {:ok, ref}

  defp require_reference(_), do: {:error, "reference is required"}

  # -- Reference parsing --------------------------------------------------------
  # Uses Code.string_to_quoted/1 to parse the reference into an AST, then
  # extracts module, function, and arity from known AST shapes.

  defp parse_reference(ref) do
    {callback?, rest} =
      case ref do
        "c:" <> r -> {true, r}
        _ -> {false, ref}
      end

    case Code.string_to_quoted(rest) do
      {:ok, ast} ->
        case ast_to_parsed(ast, callback?) do
          {:ok, parsed} -> {:ok, parsed}
          :error -> {:error, "invalid reference format: \"#{ref}\""}
        end

      {:error, details} ->
        {:error, "invalid reference: could not parse \"#{ref}\" — #{inspect(details)}"}
    end
  end

  # Module only: Enum → {:__aliases__, _, [:Enum]}
  defp ast_to_parsed({:__aliases__, _, parts}, callback?) do
    {:ok,
     %{
       module: parts_to_module(parts),
       display: parts_to_display(parts),
       function: nil,
       arity: nil,
       callback?: callback?
     }}
  end

  # Module.function/arity: Enum.map/2 → {:/, _, [remote_call, 2]}
  defp ast_to_parsed({:/, _, [call, arity]}, callback?) when is_integer(arity) do
    case call do
      {{:., _, [{:__aliases__, _, parts}, fun]}, _, []} when is_atom(fun) ->
        {:ok,
         %{
           module: parts_to_module(parts),
           display: parts_to_display(parts),
           function: fun,
           arity: arity,
           callback?: callback?
         }}

      {{:., _, [erlang_mod, fun]}, _, []} when is_atom(fun) and is_atom(erlang_mod) ->
        {:ok,
         %{
           module: erlang_mod,
           display: inspect(erlang_mod),
           function: fun,
           arity: arity,
           callback?: callback?
         }}

      _ ->
        :error
    end
  end

  # Module.function: Enum.map → {{:., _, [alias, :fun]}, _, []}
  defp ast_to_parsed({{:., _, [{:__aliases__, _, parts}, fun]}, _, []}, callback?)
       when is_atom(fun) do
    {:ok,
     %{
       module: parts_to_module(parts),
       display: parts_to_display(parts),
       function: fun,
       arity: nil,
       callback?: callback?
     }}
  end

  # Erlang module only: :gen_server → atom
  defp ast_to_parsed(atom, callback?) when is_atom(atom) do
    {:ok,
     %{
       module: atom,
       display: inspect(atom),
       function: nil,
       arity: nil,
       callback?: callback?
     }}
  end

  # Erlang function without arity: :gen_server.call
  defp ast_to_parsed({{:., _, [erlang_mod, fun]}, _, []}, callback?)
       when is_atom(fun) and is_atom(erlang_mod) do
    {:ok,
     %{
       module: erlang_mod,
       display: inspect(erlang_mod),
       function: fun,
       arity: nil,
       callback?: callback?
     }}
  end

  defp ast_to_parsed(_, _), do: :error

  # Handles the "Elixir.Enum" edge case — Module.concat([:Elixir, :Enum])
  # would produce "Elixir.Enum" (= :"Elixir.Elixir.Enum") which is wrong.
  # Stripping the leading :Elixir part gives the correct module.
  defp parts_to_module([:"Elixir" | rest]), do: Module.concat(rest)
  defp parts_to_module(parts), do: Module.concat(parts)

  defp parts_to_display(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  # -- Fetch and format ---------------------------------------------------------

  # Module-only reference (no function specified)
  defp fetch_and_format(%{function: nil, arity: nil, callback?: false} = parsed) do
    with {:ok, docs_v1} <- fetch_docs(parsed.module) do
      {:ok, format_module_docs(parsed.display, docs_v1)}
    end
  end

  # Module-only reference with callback flag (c:Module) — show only callbacks
  defp fetch_and_format(%{function: nil, arity: nil, callback?: true} = parsed) do
    with {:ok, docs_v1} <- fetch_docs(parsed.module) do
      {:ok, format_module_docs(parsed.display, docs_v1, callbacks_only: true)}
    end
  end

  # Function-specific reference
  defp fetch_and_format(parsed) do
    with {:ok, docs_v1} <- fetch_docs(parsed.module) do
      {:ok, format_function_docs(parsed, docs_v1)}
    end
  end

  defp fetch_docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _, _, _} = docs ->
        {:ok, docs}

      {:error, :chunk_not_found} ->
        {:error, "module #{inspect(module)} has no documentation"}

      {:error, :non_existing} ->
        {:error, "module #{inspect(module)} does not exist or is not loaded"}

      {:error, :module_not_found} ->
        {:error, "module #{inspect(module)} does not exist or is not loaded"}

      {:error, reason} ->
        {:error, "could not fetch docs for #{inspect(module)}: #{inspect(reason)}"}
    end
  end

  # -- Module docs formatting ---------------------------------------------------

  defp format_module_docs(display, docs_v1, opts \\ []) do
    {:docs_v1, _, _, _format, module_doc, _meta, docs} = docs_v1
    callbacks_only = Keyword.get(opts, :callbacks_only, false)

    heading = "# #{display}"

    mod_doc_section =
      case module_doc do
        {_, doc} when is_binary(doc) and doc != "" ->
          "\n\n#{doc}"

        {:hidden, _} ->
          "\n\n*Module documentation is hidden.*"

        _ ->
          "\n\n*No module documentation available.*"
      end

    target_kinds =
      if callbacks_only,
        do: [:callback, :macrocallback],
        else: [:function, :macro, :callback, :macrocallback]

    entries =
      docs
      |> Enum.filter(fn {{kind, _, _}, _, _, _, _} -> kind in target_kinds end)
      |> Enum.sort_by(fn {{kind, name, arity}, _, _, _, _} ->
        {kind_order(kind), name, arity}
      end)

    functions_section =
      if entries == [] do
        if callbacks_only, do: "\n\n*No callbacks found.*", else: ""
      else
        section_heading =
          if callbacks_only, do: "## Callbacks", else: "## Functions & Callbacks"

        formatted = entries |> Enum.map(&format_entry/1) |> Enum.join("\n\n")
        "\n\n#{section_heading}\n\n" <> formatted
      end

    heading <> mod_doc_section <> functions_section
  end

  defp kind_order(:callback), do: 0
  defp kind_order(:macrocallback), do: 0
  defp kind_order(:function), do: 1
  defp kind_order(:macro), do: 1
  defp kind_order(_), do: 2

  # -- Function docs formatting --------------------------------------------------

  defp format_function_docs(parsed, docs_v1) do
    %{function: fun, arity: arity, callback?: callback?, display: display} = parsed
    {:docs_v1, _, _, _format, _module_doc, _meta, docs} = docs_v1

    target_kinds =
      if callback?, do: [:callback, :macrocallback], else: [:function, :macro]

    matching =
      docs
      |> Enum.filter(fn {{kind, name, a}, _, _, _, _} ->
        kind in target_kinds and name == fun and (arity == nil or a == arity)
      end)
      |> Enum.sort_by(fn {{_, _, a}, _, _, _, _} -> a end)

    case matching do
      [] ->
        kind_label = if callback?, do: "callback", else: "function"
        "No #{kind_label} `#{Atom.to_string(fun)}/#{arity || "_"}` found in `#{display}`."

      entries ->
        prefix = if callback?, do: "c:", else: ""
        header_arity = if arity, do: "/#{arity}", else: ""
        header = "# #{prefix}#{display}.#{Atom.to_string(fun)}#{header_arity}\n\n"
        formatted = entries |> Enum.map(&format_entry/1) |> Enum.join("\n\n")
        header <> formatted
    end
  end

  # -- Entry formatting ---------------------------------------------------------

  defp format_entry({{kind, name, arity}, _anno, signature, doc, _meta}) do
    heading =
      case kind do
        :callback -> "### callback #{name}/#{arity}"
        :macrocallback -> "### macrocallback #{name}/#{arity}"
        :macro -> "### macro #{name}/#{arity}"
        _ -> "### #{name}/#{arity}"
      end

    sig_block =
      case signature do
        [] -> ""
        sigs -> "\n\n```elixir\n" <> Enum.join(sigs, "\n") <> "\n```"
      end

    doc_block =
      case doc do
        {_, d} when is_binary(d) and d != "" -> "\n\n" <> d
        {:hidden, _} -> "\n\n*Documentation is hidden.*"
        _ -> ""
      end

    heading <> sig_block <> doc_block
  end
end
