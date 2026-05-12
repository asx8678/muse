defmodule Muse.MatrixManager do
  @moduledoc """
  Project Semantic Index — the "GPS Map" of the project.

  The Matrix knows what every file does, how files depend on each other,
  and what the project's overall purpose is. The Planner queries this
  instead of blindly scanning files.

  ## State Structure

  The Matrix maintains:

    * `project_soul` — A summary of the project purpose and architecture
    * `files` — Per-file metadata (summary, imports, defines, deps, mtime)
    * `dep_graph` — Directed dependency graph (file → files it depends on)
    * `git_head` — Last indexed git HEAD SHA (for cache invalidation)

  ## Caching

  The matrix is cached at `<workspace_root>/.muse/matrix.cache` as JSON.
  Cache is automatically loaded on startup if git HEAD hasn't changed.
  Cache is invalidated when git HEAD changes or when `refresh/0` or
  `index_project/1` is called.

  ## Usage

      Muse.MatrixManager.index_project("/path/to/project")
      Muse.MatrixManager.query("auth logic")
      Muse.MatrixManager.get_affected_files("lib/muse/session.ex")
      Muse.MatrixManager.project_soul()
  """

  use GenServer

  require Logger

  # -- Constants ----------------------------------------------------------------

  @cache_version 1
  @default_max_files 200
  @cache_filename "matrix.cache"

  @skip_dirs MapSet.new(~w(_build deps node_modules .git .muse priv/static rel cover))
  @binary_exts MapSet.new(~w(.png .jpg .jpeg .gif .bmp .ico .svg .woff .woff2 .ttf .eot
                              .zip .gz .tar .bz2 .7z .xz .so .dll .dylib .o .a .beam .class
                              .pdf .doc .docx .xls .xlsx .ppt .pptx .pem .key .p12 .pfx
                              .sqlite .db .dat .bin .exe .app .dmg .iso .img))
  @skip_exts MapSet.new(~w(.lock .map))

  # -- Types --------------------------------------------------------------------

  @type file_entry :: %{
          summary: String.t(),
          imports: [String.t()],
          defines: [String.t()],
          deps: [String.t()],
          last_modified: DateTime.t() | nil
        }

  @type query_result ::
          {file_path :: String.t(), match_context :: String.t(), relevance :: float()}

  @type state :: %{
          project_root: String.t(),
          project_soul: String.t(),
          files: %{String.t() => file_entry()},
          dep_graph: %{String.t() => [String.t()]},
          git_head: String.t() | nil,
          max_files: pos_integer()
        }

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec index_project(String.t()) :: :ok
  def index_project(root) when is_binary(root) do
    GenServer.call(__MODULE__, {:index_project, root}, :timer.minutes(5))
  end

  @spec refresh() :: :ok
  def refresh do
    GenServer.call(__MODULE__, :refresh, :timer.minutes(5))
  end

  @spec query(String.t()) :: [query_result()]
  def query(query_string) when is_binary(query_string) do
    GenServer.call(__MODULE__, {:query, query_string})
  end

  @spec get_file_summary(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get_file_summary(path) when is_binary(path) do
    GenServer.call(__MODULE__, {:get_file_summary, path})
  end

  @spec get_affected_files(String.t()) :: [String.t()]
  def get_affected_files(path) when is_binary(path) do
    GenServer.call(__MODULE__, {:get_affected_files, path})
  end

  @spec project_soul() :: String.t()
  def project_soul do
    GenServer.call(__MODULE__, :project_soul)
  end

  # -- GenServer callbacks ------------------------------------------------------

  @impl true
  def init(opts) do
    root = Keyword.get(opts, :root, ".") |> Path.expand()
    max_files = Keyword.get(opts, :max_files, @default_max_files)

    state = %{
      project_root: root,
      project_soul: "",
      files: %{},
      dep_graph: %{},
      git_head: nil,
      max_files: max_files
    }

    case try_load_cache(root, max_files) do
      {:ok, cached_state} ->
        {:ok, cached_state}

      :miss ->
        # Trigger async index — don't block supervisor startup
        send(self(), {:async_index, root})
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:index_project, root}, _from, state) do
    new_state = do_index_project(root, state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    new_state = do_refresh(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:query, query_string}, _from, state) do
    results = do_query(query_string, state)
    {:reply, results, state}
  end

  @impl true
  def handle_call({:get_file_summary, path}, _from, state) do
    result =
      case Map.get(state.files, path) do
        nil ->
          # Try resolving as relative path from project root
          case find_file_entry(path, state) do
            nil -> {:error, :not_found}
            entry -> {:ok, entry.summary}
          end

        entry ->
          {:ok, entry.summary}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_affected_files, path}, _from, state) do
    affected = compute_affected_files(path, state)
    {:reply, affected, state}
  end

  @impl true
  def handle_call(:project_soul, _from, state) do
    {:reply, state.project_soul, state}
  end

  @impl true
  def handle_info({:async_index, root}, state) do
    new_state = do_index_project(root, state)
    {:noreply, new_state}
  end

  # -- Full re-index ------------------------------------------------------------

  defp do_index_project(root, state) do
    root = Path.expand(root)
    Logger.info("MatrixManager: full re-index of #{root}")

    candidate_files = walk_project(root)
    {selected, skipped} = select_files(candidate_files, state.max_files)

    if skipped > 0 do
      Logger.info(
        "MatrixManager: selected #{length(selected)} of #{length(candidate_files)} files (limit: #{state.max_files})"
      )
    end

    {module_map, file_entries} = build_all_entries(root, selected)
    dep_graph = build_dep_graph(file_entries, module_map)
    project_soul = generate_project_soul(file_entries, root)
    git_head = read_git_head(root)

    new_state = %{
      state
      | project_root: root,
        project_soul: project_soul,
        files: file_entries,
        dep_graph: dep_graph,
        git_head: git_head
    }

    save_cache(new_state)
    new_state
  end

  # -- Incremental refresh ------------------------------------------------------

  defp do_refresh(state) do
    root = state.project_root
    current_git_head = read_git_head(root)

    if current_git_head != nil and current_git_head != state.git_head do
      # Git HEAD changed — full re-index
      do_index_project(root, state)
    else
      do_incremental_refresh(root, state)
    end
  end

  defp do_incremental_refresh(root, state) do
    candidate_files = walk_project(root)
    current_mtimes = read_file_mtimes(root, candidate_files)

    changed_paths =
      Enum.filter(candidate_files, fn rel_path ->
        current_mtime = Map.get(current_mtimes, rel_path)
        old_entry = Map.get(state.files, rel_path)

        cond do
          is_nil(current_mtime) -> false
          is_nil(old_entry) -> true
          old_entry.last_modified == nil -> true
          DateTime.compare(current_mtime, old_entry.last_modified) != :eq -> true
          true -> false
        end
      end)

    # Always prune deleted files, even when no mtimes changed
    existing_set = MapSet.new(candidate_files)
    pruned_files = Map.filter(state.files, fn {p, _} -> MapSet.member?(existing_set, p) end)

    has_deletions = map_size(pruned_files) < map_size(state.files)
    has_additions = Enum.any?(candidate_files, &is_nil(Map.get(state.files, &1)))

    if changed_paths == [] and not has_deletions and not has_additions do
      Logger.info("MatrixManager: no changes detected")
      state
    else
      Logger.info("MatrixManager: incremental refresh, #{length(changed_paths)} files changed")

      {_module_map, new_entries} = build_all_entries(root, changed_paths)

      merged_files =
        pruned_files
        |> Map.merge(new_entries)

      full_module_map = build_full_module_map(merged_files)
      dep_graph = build_dep_graph(merged_files, full_module_map)
      project_soul = generate_project_soul(merged_files, root)

      new_state = %{
        state
        | files: merged_files,
          dep_graph: dep_graph,
          project_soul: project_soul
      }

      save_cache(new_state)
      new_state
    end
  end

  # -- File walking -------------------------------------------------------------

  defp walk_project(root) do
    walk_dir(root, root) |> Enum.sort()
  end

  defp walk_dir(dir, root) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            skip_dir?(entry) ->
              []

            File.dir?(path) ->
              walk_dir(path, root)

            skip_file?(entry) ->
              []

            true ->
              [Path.relative_to(path, root)]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp skip_dir?(name) do
    down = String.downcase(name)
    MapSet.member?(@skip_dirs, down) or (String.starts_with?(down, ".") and down != ".")
  end

  defp skip_file?(name) do
    ext = String.downcase(Path.extname(name))
    MapSet.member?(@binary_exts, ext) or MapSet.member?(@skip_exts, ext)
  end

  # -- File selection (large-project cap) ---------------------------------------

  defp select_files(files, max_files) when length(files) <= max_files do
    {files, 0}
  end

  defp select_files(files, max_files) do
    selected =
      files
      |> Enum.sort_by(&file_priority/1)
      |> Enum.take(max_files)

    {selected, length(files) - max_files}
  end

  defp file_priority(path) do
    cond do
      String.starts_with?(path, "lib/") -> 0
      String.starts_with?(path, "test/") -> 1
      String.starts_with?(path, "config/") -> 2
      true -> 3
    end
  end

  # -- File entry building ------------------------------------------------------

  defp build_all_entries(root, rel_paths) do
    Enum.reduce(rel_paths, {%{}, %{}}, fn rel_path, {mod_map, ents} ->
      abs_path = Path.join(root, rel_path)

      case build_file_entry(abs_path, rel_path) do
        {:ok, entry, modules} ->
          updated_mod_map =
            Enum.reduce(modules, mod_map, fn mod, acc -> Map.put(acc, mod, rel_path) end)

          {updated_mod_map, Map.put(ents, rel_path, entry)}

        {:skip, _reason} ->
          {mod_map, ents}
      end
    end)
    |> then(fn {mod_map, ents} ->
      {mod_map, resolve_deps(ents, mod_map)}
    end)
  end

  defp build_file_entry(abs_path, rel_path) do
    ext = String.downcase(Path.extname(rel_path))

    with {:ok, content} <- read_text_file(abs_path),
         {:ok, mtime} <- read_mtime(abs_path) do
      case ext do
        e when e in ~w(.ex .exs) -> build_elixir_entry(content, rel_path, mtime)
        _ -> build_text_entry(content, rel_path, mtime)
      end
    else
      {:error, reason} ->
        {:skip, reason}
    end
  end

  defp read_text_file(path) do
    case File.read(path) do
      {:ok, content} ->
        if String.valid?(content) do
          {:ok, content}
        else
          Logger.warning("MatrixManager: skipping non-UTF-8 file #{path}")
          {:error, :non_utf8}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_mtime(path) do
    case File.stat(path, time: :universal) do
      {:ok, %File.Stat{mtime: mtime}} ->
        {:ok, mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_file_mtimes(root, rel_paths) do
    Enum.reduce(rel_paths, %{}, fn rel_path, acc ->
      abs_path = Path.join(root, rel_path)

      case read_mtime(abs_path) do
        {:ok, mtime} -> Map.put(acc, rel_path, mtime)
        {:error, _} -> acc
      end
    end)
  end

  # -- Elixir AST parsing -------------------------------------------------------

  defp build_elixir_entry(source, rel_path, mtime) do
    try do
      case Code.string_to_quoted(source, columns: false, token_metadata: false) do
        {:ok, ast} ->
          acc = walk_ast(ast, nil, %{modules: [], functions: [], imports: []})
          summary = generate_summary(rel_path, acc)

          entry = %{
            summary: summary,
            imports: Enum.uniq(acc.imports),
            defines: Enum.uniq(acc.modules ++ acc.functions),
            deps: [],
            last_modified: mtime
          }

          {:ok, entry, acc.modules}

        {:error, {line, error, token}} ->
          Logger.warning(
            "MatrixManager: parse error in #{rel_path}:#{line} #{inspect(error)} token: #{inspect(token)}"
          )

          entry = %{
            summary: "Elixir file (parse error at line #{line})",
            imports: [],
            defines: [],
            deps: [],
            last_modified: mtime
          }

          {:ok, entry, []}
      end
    rescue
      e ->
        Logger.warning(
          "MatrixManager: unexpected error parsing #{rel_path}: #{Exception.message(e)}"
        )

        entry = %{
          summary: "Elixir file (parse error)",
          imports: [],
          defines: [],
          deps: [],
          last_modified: mtime
        }

        {:ok, entry, []}
    end
  end

  # defmodule with standard aliased name
  defp walk_ast({:defmodule, _, [{:__aliases__, _, parts} | rest]}, _ctx, acc)
       when is_list(parts) do
    module = Enum.join(parts, ".")
    acc = %{acc | modules: [module | acc.modules]}
    body = extract_do_block(rest)
    if body, do: walk_ast(body, module, acc), else: acc
  end

  # def/defp/defmacro/defmacrop
  defp walk_ast({def_type, _, [head | opts]}, module, acc)
       when def_type in [:def, :defp, :defmacro, :defmacrop] do
    {name, arity} = extract_function_head(head)
    qualified = if module, do: "#{module}.#{name}/#{arity}", else: "#{name}/#{arity}"
    acc = %{acc | functions: [qualified | acc.functions]}
    body = extract_do_block(opts)
    if body, do: walk_ast(body, module, acc), else: acc
  end

  # import/alias/use/require with module reference
  defp walk_ast({import_type, _, [module_ref | _]}, _module, acc)
       when import_type in [:import, :alias, :use, :require] do
    case extract_module_ref(module_ref) do
      nil -> acc
      name -> %{acc | imports: [name | acc.imports]}
    end
  end

  # Generic 3-tuple: recurse into children
  defp walk_ast({_, _, children}, ctx, acc) when is_list(children) do
    Enum.reduce(children, acc, &walk_ast(&1, ctx, &2))
  end

  # List of AST nodes
  defp walk_ast(list, ctx, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk_ast(&1, ctx, &2))
  end

  # Catch-all: ignore scalars, 2-tuples, etc.
  defp walk_ast(_, _, acc), do: acc

  defp extract_do_block(rest) when is_list(rest) do
    case List.last(rest) do
      opts when is_list(opts) -> Keyword.get(opts, :do)
      _ -> nil
    end
  end

  defp extract_do_block(_), do: nil

  defp extract_function_head({:when, _, [head | _]}), do: extract_function_head(head)

  defp extract_function_head({name, _, args}) when is_atom(name) do
    arity =
      case args do
        nil -> 0
        list when is_list(list) -> length(list)
        _ -> 0
      end

    {name, arity}
  end

  defp extract_function_head(_), do: {:unknown, 0}

  defp extract_module_ref({:__aliases__, _, parts}) when is_list(parts) do
    Enum.join(parts, ".")
  end

  defp extract_module_ref(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp extract_module_ref(_), do: nil

  # -- Non-Elixir file parsing --------------------------------------------------

  defp build_text_entry(source, rel_path, mtime) do
    imports = extract_text_imports(source, rel_path)
    summary = generate_text_summary(rel_path, source, imports)

    entry = %{
      summary: summary,
      imports: imports,
      defines: [],
      deps: [],
      last_modified: mtime
    }

    {:ok, entry, []}
  end

  @ts_import_re ~r/import\s+.*?from\s+['"](.+?)['"]/
  @ts_require_re ~r/require\s*\(\s*['"](.+?)['"]\s*\)/
  @py_import_re ~r/^(?:from\s+(\S+)\s+)?import\s+(\S+)/m
  @rb_require_re ~r/require(?:_relative)?\s+['"](.+?)['"]/
  @go_import_re ~r/"([^"]+)"\s*$/

  defp extract_text_imports(source, rel_path) do
    ext = String.downcase(Path.extname(rel_path))

    case ext do
      e when e in ~w(.ts .tsx .js .jsx) -> extract_js_imports(source)
      ".py" -> extract_py_imports(source)
      ".rb" -> extract_rb_imports(source)
      ".go" -> extract_go_imports(source)
      _ -> []
    end
  end

  defp extract_js_imports(source) do
    (Regex.scan(@ts_import_re, source, capture: :all_but_first) ++
       Regex.scan(@ts_require_re, source, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
  end

  defp extract_py_imports(source) do
    Regex.scan(@py_import_re, source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_rb_imports(source) do
    Regex.scan(@rb_require_re, source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp extract_go_imports(source) do
    Regex.scan(@go_import_re, source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  # -- Summary generation -------------------------------------------------------

  defp generate_summary(rel_path, acc) do
    modules = acc.modules
    functions = acc.functions

    module_part =
      case modules do
        [] ->
          ""

        [single] ->
          "Defines #{single}"

        multiple ->
          names = Enum.take(multiple, 3) |> Enum.join(", ")
          rest = if length(multiple) > 3, do: " and #{length(multiple) - 3} more", else: ""
          "Defines #{names}#{rest}"
      end

    fun_part =
      case functions do
        [] -> ""
        _ -> " with #{length(functions)} functions"
      end

    summary = String.trim("#{module_part}#{fun_part}")
    if summary == "", do: "Elixir file: #{rel_path}", else: summary
  end

  defp generate_text_summary(rel_path, source, imports) do
    ext = Path.extname(rel_path)
    line_count = source |> String.split("\n") |> length()

    import_part =
      case imports do
        [] -> ""
        _ -> " imports: #{Enum.join(Enum.take(imports, 3), ", ")}"
      end

    "#{ext} file (#{line_count} lines)#{import_part}"
  end

  # -- Project soul generation --------------------------------------------------

  defp generate_project_soul(files, root) do
    file_count = map_size(files)

    if file_count == 0 do
      "Empty project at #{Path.basename(root)}."
    else
      modules =
        files
        |> Enum.flat_map(fn {_, e} -> e.defines end)
        |> Enum.filter(&(not String.contains?(&1, "/")))

      module_count = length(modules)

      top_modules = Enum.take(modules, 20)

      namespaces =
        top_modules
        |> Enum.map(fn mod ->
          case String.split(mod, ".") do
            [first | _] -> first
            _ -> mod
          end
        end)
        |> Enum.uniq()
        |> Enum.take(10)

      dep_count =
        files
        |> Enum.flat_map(fn {_, e} -> e.deps end)
        |> Enum.uniq()
        |> length()

      ext_counts =
        files
        |> Enum.frequencies_by(fn {path, _} -> Path.extname(path) end)
        |> Enum.sort_by(fn {_, count} -> -count end)
        |> Enum.take(5)

      ext_summary =
        ext_counts
        |> Enum.map(fn {ext, count} -> "#{ext}: #{count}" end)
        |> Enum.join(", ")

      file_summaries =
        files
        |> Enum.take(50)
        |> Enum.map(fn {path, entry} -> "  #{path}: #{entry.summary}" end)

      [
        "Project at #{Path.basename(root)}: #{file_count} indexed files, #{module_count} modules, #{dep_count} dependency links.",
        "File types: #{ext_summary}.",
        if(namespaces != [],
          do: "Top-level namespaces: #{Enum.join(namespaces, ", ")}.",
          else: nil
        ),
        if(top_modules != [], do: "Key modules: #{Enum.join(top_modules, ", ")}.", else: nil),
        "",
        "File summaries:"
        | file_summaries
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end
  end

  # -- Dependency graph ---------------------------------------------------------

  defp build_dep_graph(file_entries, module_map) do
    Map.new(file_entries, fn {rel_path, entry} ->
      deps =
        entry.imports
        |> Enum.map(&Map.get(module_map, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&(&1 == rel_path))
        |> Enum.uniq()

      {rel_path, deps}
    end)
  end

  defp resolve_deps(file_entries, module_map) do
    Map.new(file_entries, fn {rel_path, entry} ->
      deps =
        entry.imports
        |> Enum.map(&Map.get(module_map, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&(&1 == rel_path))
        |> Enum.uniq()

      {rel_path, %{entry | deps: deps}}
    end)
  end

  defp build_full_module_map(file_entries) do
    file_entries
    |> Enum.flat_map(fn {rel_path, entry} ->
      entry.defines
      |> Enum.filter(&(not String.contains?(&1, "/")))
      |> Enum.map(&{&1, rel_path})
    end)
    |> Map.new()
  end

  # -- Query system -------------------------------------------------------------

  defp do_query(query_string, state) do
    terms = parse_query_terms(query_string)

    if terms == [] do
      []
    else
      state.files
      |> Enum.flat_map(fn {path, entry} ->
        score = compute_relevance(path, entry, terms)

        if score > 0.0 do
          context = build_match_context(path, entry, terms)
          [{path, context, score}]
        else
          []
        end
      end)
      |> Enum.sort_by(fn {_, _, score} -> -score end)
      |> Enum.take(50)
    end
  end

  defp parse_query_terms(query_string) do
    query_string
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(fn term ->
      if String.ends_with?(term, "*") do
        {:prefix, String.replace_suffix(term, "*", "")}
      else
        {:exact, term}
      end
    end)
  end

  defp compute_relevance(path, entry, terms) do
    path_lower = String.downcase(path)
    summary_lower = String.downcase(entry.summary)
    defines_lower = entry.defines |> Enum.join(" ") |> String.downcase()

    Enum.reduce(terms, 0.0, fn
      {:prefix, prefix}, acc ->
        if String.starts_with?(path_lower, prefix) or
             String.starts_with?(summary_lower, prefix) or
             String.contains?(defines_lower, prefix) do
          acc + 0.5
        else
          acc
        end

      {:exact, term}, acc ->
        cond do
          String.contains?(path_lower, term) -> acc + 1.0
          String.contains?(summary_lower, term) -> acc + 0.8
          String.contains?(defines_lower, term) -> acc + 0.6
          true -> acc
        end
    end)
  end

  defp build_match_context(path, entry, terms) do
    candidates = [
      {path, 1.0},
      {entry.summary, 0.8}
      | Enum.map(entry.defines, &{&1, 0.6})
    ]

    {best, _} =
      Enum.max_by(candidates, fn {text, weight} ->
        text_lower = String.downcase(text)

        Enum.reduce(terms, 0.0, fn
          {:prefix, prefix}, acc ->
            if String.starts_with?(text_lower, prefix), do: acc + 0.5 * weight, else: acc

          {:exact, term}, acc ->
            if String.contains?(text_lower, term), do: acc + 1.0 * weight, else: acc
        end)
      end)

    best
  end

  # -- Affected files (reverse dependency traversal) ----------------------------

  defp compute_affected_files(path, state) do
    reverse_deps = build_reverse_deps(state.dep_graph)
    initial = Map.get(reverse_deps, path, [])
    bfs_collect(initial, reverse_deps, MapSet.new(), [])
  end

  defp build_reverse_deps(dep_graph) do
    dep_graph
    |> Enum.flat_map(fn {file, deps} -> Enum.map(deps, fn dep -> {dep, file} end) end)
    |> Enum.group_by(fn {dep, _} -> dep end, fn {_, file} -> file end)
  end

  defp bfs_collect([], _reverse, _seen, acc), do: Enum.uniq(Enum.reverse(acc))

  defp bfs_collect([file | rest], reverse, seen, acc) do
    if MapSet.member?(seen, file) do
      bfs_collect(rest, reverse, seen, acc)
    else
      seen = MapSet.put(seen, file)
      dependents = Map.get(reverse, file, [])
      bfs_collect(rest ++ dependents, reverse, seen, [file | acc])
    end
  end

  # -- Utility ------------------------------------------------------------------

  defp find_file_entry(path, state) do
    # Direct lookup
    case Map.get(state.files, path) do
      nil ->
        # Try as relative path
        abs = Path.join(state.project_root, path)

        Enum.find_value(state.files, fn {rel_path, entry} ->
          if Path.join(state.project_root, rel_path) |> Path.expand() == abs, do: entry, else: nil
        end)

      entry ->
        entry
    end
  end

  # -- Cache I/O ----------------------------------------------------------------

  defp try_load_cache(root, max_files) do
    cache_path = cache_path(root)

    with {:ok, raw} <- File.read(cache_path),
         {:ok, data} <- Jason.decode(raw),
         true <- data["version"] == @cache_version do
      current_git_head = read_git_head(root)

      if data["git_head"] == current_git_head do
        {:ok, deserialize_state(data, root, max_files)}
      else
        Logger.info("MatrixManager: cache git HEAD mismatch, re-indexing")
        :miss
      end
    else
      _ -> :miss
    end
  end

  defp save_cache(state) do
    cache_path = cache_path(state.project_root)
    cache_dir = Path.dirname(cache_path)

    with :ok <- File.mkdir_p(cache_dir),
         data <- serialize_state(state),
         {:ok, json} <- Jason.encode(data, pretty: true) do
      File.write(cache_path, json)
    else
      {:error, reason} ->
        Logger.warning("MatrixManager: failed to save cache: #{inspect(reason)}")
        :ok
    end
  end

  defp cache_path(root), do: Path.join([root, ".muse", @cache_filename])

  defp serialize_state(state) do
    %{
      "version" => @cache_version,
      "git_head" => state.git_head,
      "project_root" => state.project_root,
      "project_soul" => state.project_soul,
      "files" =>
        Map.new(state.files, fn {path, entry} ->
          {path,
           %{
             "summary" => entry.summary,
             "imports" => entry.imports,
             "defines" => entry.defines,
             "deps" => entry.deps,
             "last_modified" => entry.last_modified && DateTime.to_iso8601(entry.last_modified)
           }}
        end),
      "dep_graph" => state.dep_graph
    }
  end

  defp deserialize_state(data, root, max_files) do
    files =
      Map.new(data["files"] || %{}, fn {path, entry} ->
        {path,
         %{
           summary: entry["summary"] || "",
           imports: entry["imports"] || [],
           defines: entry["defines"] || [],
           deps: entry["deps"] || [],
           last_modified: parse_datetime(entry["last_modified"])
         }}
      end)

    %{
      project_root: data["project_root"] || root,
      project_soul: data["project_soul"] || "",
      files: files,
      dep_graph: data["dep_graph"] || %{},
      git_head: data["git_head"],
      max_files: max_files
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  # -- Git HEAD -----------------------------------------------------------------

  defp read_git_head(root) do
    git_head_path = Path.join(root, ".git/HEAD")

    with {:ok, content} <- File.read(git_head_path),
         content = String.trim(content) do
      if String.starts_with?(content, "ref: ") do
        ref_path = String.replace_prefix(content, "ref: ", "")
        ref_full = Path.join(root, ".git/#{ref_path}")

        case File.read(ref_full) do
          {:ok, sha} -> String.trim(sha)
          {:error, _} -> content
        end
      else
        content
      end
    else
      {:error, _} -> nil
    end
  end
end
