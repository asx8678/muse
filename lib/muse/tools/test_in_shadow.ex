defmodule Muse.Tools.TestInShadow do
  @moduledoc """
  Run tests in an isolated shadow workspace with VFS overlay.

  Auto-detects the test framework from project type and runs the
  appropriate test command in a ShadowWorkspace, overlaying modified
  VFS files so the agent's in-memory changes are tested without
  touching the real project.

  ## Supported frameworks

    * **Elixir** (`mix.exs` present) → `mix test`
    * **JavaScript/TypeScript** (`package.json` with "test" script) → `npm test`
    * **Python** (`pytest.ini`, `pyproject.toml`, or `setup.py` present) → `pytest`

  ## Arguments

    * `files_to_include` — (optional) list of workspace-relative paths to
      overlay from VFS. If omitted, all modified VFS files are overlaid.
    * `timeout_seconds` — (optional) max execution time (default: 120)
    * `framework` — (optional) force a specific framework (`elixir`, `javascript`, `python`)

  ## Edge cases

    * No test framework detected → returns error
    * Timeout → kills process, returns partial output
    * Shadow creation fails → returns error without crashing the agent
    * VFS has no modified files for the requested paths → logs warning, uses originals
    * Very large output (10k+ lines) → truncated to last 200 lines with note
  """

  alias Muse.ActiveVFS
  alias Muse.Prompt.Redactor
  alias Muse.ShadowWorkspace
  alias Muse.Tool.Result

  @default_timeout_seconds 120
  @max_output_lines 10_000
  @truncated_tail_lines 200

  # Framework order for auto-detection
  @framework_order [:elixir, :javascript, :python]

  # Returns the framework config map for a given framework atom.
  # This function replaces a module attribute because Elixir module
  # attributes cannot store anonymous functions.
  @spec framework_config(atom()) :: %{command: String.t(), parse: (String.t() -> map())} | nil
  defp framework_config(:elixir),
    do: %{command: "mix test", parse: &Muse.Tools.TestInShadow.parse_elixir_output/1}

  defp framework_config(:javascript),
    do: %{command: "npm test", parse: &Muse.Tools.TestInShadow.parse_javascript_output/1}

  defp framework_config(:python),
    do: %{command: "pytest", parse: &Muse.Tools.TestInShadow.parse_python_output/1}

  defp framework_config(_), do: nil

  # Detect whether a framework applies to the given shadow path.
  @spec framework_detects?(atom(), String.t()) :: boolean()
  defp framework_detects?(:elixir, shadow_path),
    do: File.exists?(Path.join(shadow_path, "mix.exs"))

  defp framework_detects?(:javascript, shadow_path) do
    pkg_path = Path.join(shadow_path, "package.json")

    if File.exists?(pkg_path) do
      case File.read(pkg_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{"scripts" => %{"test" => _}}} -> true
            _ -> false
          end

        _ ->
          false
      end
    else
      false
    end
  end

  defp framework_detects?(:python, shadow_path) do
    File.exists?(Path.join(shadow_path, "pytest.ini")) or
      File.exists?(Path.join(shadow_path, "pyproject.toml")) or
      File.exists?(Path.join(shadow_path, "setup.py"))
  end

  defp framework_detects?(_, _), do: false

  @doc """
  Run tests in an isolated shadow workspace.

  Returns `%Muse.Tool.Result{}` with structured output including
  exit_code, stdout, stderr, duration_ms, framework, parsed test
  counts, and a summary string.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = Map.get(context, :workspace, "")
    timeout_seconds = parse_timeout(args)
    files_to_include = parse_files_to_include(args)
    forced_framework = parse_framework(args)

    cond do
      not valid_workspace?(workspace) ->
        Result.error("test_in_shadow", "workspace is not a valid directory: #{workspace}")

      true ->
        run_tests_in_shadow(workspace, timeout_seconds, files_to_include, forced_framework)
    end
  end

  # -- Public output parsers (exposed for testing) -----------------------------

  @doc """
  Parse ExUnit test output into a counts map.

  ## Examples

      iex> Muse.Tools.TestInShadow.parse_elixir_output("12 tests, 0 failures")
      %{total: 12, passed: 12, failed: 0, skipped: 0}

  """
  @spec parse_elixir_output(String.t()) :: %{
          total: non_neg_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def parse_elixir_output(output) do
    counts = %{total: 0, passed: 0, failed: 0, skipped: 0}

    case Regex.run(~r/(\d+)\s+tests?,\s*(\d+)\s+failures?/, output) do
      [_, total_str, failed_str] ->
        total = String.to_integer(total_str)
        failed = String.to_integer(failed_str)

        skipped =
          case Regex.run(~r/(\d+)\s+skipped/, output) do
            [_, s] -> String.to_integer(s)
            _ -> 0
          end

        %{
          counts
          | total: total,
            failed: failed,
            skipped: skipped,
            passed: total - failed - skipped
        }

      _ ->
        counts
    end
  end

  @doc """
  Parse npm/Jest/Mocha test output into a counts map.
  """
  @spec parse_javascript_output(String.t()) :: %{
          total: non_neg_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def parse_javascript_output(output) do
    cond do
      # Jest-style
      match = Regex.run(~r/Tests:\s*(\d+)\s*passed,\s*(\d+)\s*failed,\s*(\d+)\s*total/, output) ->
        [_, passed_str, failed_str, total_str] = match
        total = String.to_integer(total_str)
        failed = String.to_integer(failed_str)
        passed = String.to_integer(passed_str)
        %{total: total, passed: passed, failed: failed, skipped: total - passed - failed}

      # Mocha-style
      match = Regex.run(~r/(\d+)\s+passing/, output) ->
        [_, passed_str] = match
        passed = String.to_integer(passed_str)

        failed =
          case Regex.run(~r/(\d+)\s+failing/, output) do
            [_, f] -> String.to_integer(f)
            _ -> 0
          end

        %{total: passed + failed, passed: passed, failed: failed, skipped: 0}

      # Generic
      true ->
        %{total: 0, passed: 0, failed: 0, skipped: 0}
    end
  end

  @doc """
  Parse pytest output into a counts map.
  """
  @spec parse_python_output(String.t()) :: %{
          total: non_neg_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def parse_python_output(output) do
    passed =
      case Regex.run(~r/(\d+)\s+passed/, output) do
        [_, p] -> String.to_integer(p)
        _ -> 0
      end

    failed =
      case Regex.run(~r/(\d+)\s+failed/, output) do
        [_, f] -> String.to_integer(f)
        _ -> 0
      end

    skipped =
      case Regex.run(~r/(\d+)\s+skipped/, output) do
        [_, s] -> String.to_integer(s)
        _ -> 0
      end

    total = passed + failed + skipped

    %{total: total, passed: passed, failed: failed, skipped: skipped}
  end

  # -- Private: shadow lifecycle ------------------------------------------------

  defp run_tests_in_shadow(workspace, timeout_seconds, files_to_include, forced_framework) do
    start_time = System.monotonic_time(:millisecond)

    case ShadowWorkspace.create(workspace) do
      {:ok, shadow} ->
        try do
          overlay_vfs_files(shadow, files_to_include)

          case detect_framework(shadow.path, forced_framework) do
            {:ok, framework, command, parser} ->
              timeout_ms = timeout_seconds * 1_000

              case ShadowWorkspace.run(shadow, command, timeout: timeout_ms) do
                {:ok, run_result} ->
                  duration_ms = System.monotonic_time(:millisecond) - start_time
                  build_test_result(run_result, command, framework, parser, duration_ms)
              end

            {:error, reason} ->
              Result.error("test_in_shadow", reason)
          end
        after
          ShadowWorkspace.destroy(shadow)
        end

      {:error, reason} ->
        Result.error("test_in_shadow", "shadow creation failed: #{inspect(reason)}")
    end
  end

  # -- Private: VFS overlay ----------------------------------------------------

  defp overlay_vfs_files(shadow, files_to_include) do
    paths = resolve_overlay_paths(files_to_include)

    Enum.each(paths, fn path ->
      case ActiveVFS.read(path) do
        {:ok, content} ->
          case ShadowWorkspace.write_file(shadow, path, content) do
            :ok ->
              :ok

            {:error, reason} ->
              require Logger
              Logger.warning("TestInShadow: failed to overlay #{path}: #{inspect(reason)}")
          end

        {:error, reason} ->
          require Logger
          Logger.warning("TestInShadow: VFS read failed for #{path}: #{inspect(reason)}")
      end
    end)
  end

  defp resolve_overlay_paths(nil), do: safe_modified_files()
  defp resolve_overlay_paths([]), do: safe_modified_files()
  defp resolve_overlay_paths(paths) when is_list(paths), do: paths

  defp safe_modified_files do
    try do
      case Process.whereis(ActiveVFS) do
        nil -> []
        _pid -> ActiveVFS.modified_files()
      end
    rescue
      _ -> []
    end
  end

  # -- Private: framework detection --------------------------------------------

  defp detect_framework(shadow_path, nil) do
    case find_framework(shadow_path) do
      {:ok, framework} ->
        config = framework_config(framework)
        {:ok, framework, config.command, config.parse}

      :none ->
        {:error,
         "no test framework detected (looked for mix.exs, package.json with test script, pytest.ini/pyproject.toml/setup.py)"}
    end
  end

  defp detect_framework(_shadow_path, forced) when is_atom(forced) do
    case framework_config(forced) do
      nil ->
        {:error, "unknown framework: #{forced} (supported: elixir, javascript, python)"}

      config ->
        {:ok, forced, config.command, config.parse}
    end
  end

  defp detect_framework(_shadow_path, forced) when is_binary(forced) do
    normalized = String.downcase(forced)

    case normalized do
      "elixir" -> detect_framework(nil, :elixir)
      "javascript" -> detect_framework(nil, :javascript)
      "js" -> detect_framework(nil, :javascript)
      "typescript" -> detect_framework(nil, :javascript)
      "ts" -> detect_framework(nil, :javascript)
      "python" -> detect_framework(nil, :python)
      "py" -> detect_framework(nil, :python)
      _ -> {:error, "unknown framework: #{forced} (supported: elixir, javascript, python)"}
    end
  end

  defp find_framework(shadow_path) do
    Enum.find_value(@framework_order, :none, fn framework ->
      if framework_detects?(framework, shadow_path) do
        {:ok, framework}
      end
    end)
  end

  # -- Private: result construction ---------------------------------------------

  defp build_test_result(run_result, command, framework, parser, duration_ms) do
    stdout = truncate_output(run_result.stdout)
    stderr = run_result.stderr || ""
    exit_code = run_result.exit_code
    timed_out = Map.get(run_result, :timed_out, false)
    test_counts = parser.(stdout)

    passed = exit_code == 0 and not timed_out and test_counts.failed == 0
    summary = build_summary(test_counts, timed_out)

    Result.ok("test_in_shadow", %{
      exit_code: exit_code,
      stdout: redact_output(stdout),
      stderr: redact_output(stderr),
      passed: passed,
      summary: summary,
      duration_ms: duration_ms,
      timed_out: timed_out,
      framework: framework,
      test_counts: test_counts,
      command: command
    })
  end

  # -- Private: output truncation ----------------------------------------------

  defp truncate_output(output) when is_binary(output) do
    lines = String.split(output, "\n")

    if length(lines) > @max_output_lines do
      tail = Enum.take(lines, -@truncated_tail_lines)

      "[output truncated: showing last #{@truncated_tail_lines} of #{length(lines)} lines]\n" <>
        Enum.join(tail, "\n")
    else
      output
    end
  end

  defp truncate_output(output), do: output

  # -- Private: summary ---------------------------------------------------------

  defp build_summary(_counts, true) do
    "tests timed out"
  end

  defp build_summary(%{total: 0}, false) do
    "no test results parsed"
  end

  defp build_summary(%{total: total, passed: passed, failed: failed, skipped: skipped}, false) do
    parts = ["#{passed} passed"]

    parts =
      if failed > 0 do
        parts ++ ["#{failed} failed"]
      else
        parts
      end

    parts =
      if skipped > 0 do
        parts ++ ["#{skipped} skipped"]
      else
        parts
      end

    "#{total} tests, " <> Enum.join(parts, ", ")
  end

  # -- Private: safety helpers --------------------------------------------------

  defp valid_workspace?(workspace) when is_binary(workspace) do
    File.dir?(workspace)
  end

  defp valid_workspace?(_), do: false

  defp parse_timeout(args) do
    raw = Map.get(args, "timeout_seconds") || Map.get(args, :timeout_seconds)

    case raw do
      nil ->
        @default_timeout_seconds

      n when is_integer(n) and n > 0 ->
        min(n, 600)

      n when is_binary(n) ->
        case Integer.parse(n) do
          {val, _} when val > 0 -> min(val, 600)
          _ -> @default_timeout_seconds
        end

      _ ->
        @default_timeout_seconds
    end
  end

  defp parse_files_to_include(args) do
    raw = Map.get(args, "files_to_include") || Map.get(args, :files_to_include)

    case raw do
      nil -> nil
      paths when is_list(paths) -> Enum.filter(paths, &is_binary/1)
      _ -> nil
    end
  end

  defp parse_framework(args) do
    raw = Map.get(args, "framework") || Map.get(args, :framework)

    case raw do
      nil -> nil
      f when is_atom(f) -> f
      f when is_binary(f) -> f
      _ -> nil
    end
  end

  defp redact_output(text) when is_binary(text) do
    Redactor.redact_text(text)
  end

  defp redact_output(text), do: text
end
