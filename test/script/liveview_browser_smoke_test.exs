defmodule Muse.Script.LiveViewBrowserSmokeTest do
  use ExUnit.Case, async: false

  @script Path.join(File.cwd!(), "script/liveview-browser-smoke")

  describe "script/liveview-browser-smoke orchestration" do
    test "rejects invalid ports before invoking mix" do
      ctx = fake_tools()

      {output, status} =
        run_script(ctx.env ++ [{"MUSE_BROWSER_SMOKE_PORT", "70000"}])

      assert status == 1
      assert output =~ "invalid MUSE_BROWSER_SMOKE_PORT '70000'; must be in 1..65535"
      assert read_optional(ctx.mix_calls) == ""
    end

    test "rejects invalid host values before invoking mix" do
      ctx = fake_tools()

      {output, status} =
        run_script(ctx.env ++ [{"MUSE_BROWSER_SMOKE_HOST", "http://127.0.0.1:4210"}])

      assert status == 1
      assert output =~ "invalid MUSE_BROWSER_SMOKE_HOST 'http://127.0.0.1:4210'"
      assert output =~ "without scheme, port, or path"
      assert read_optional(ctx.mix_calls) == ""
    end

    test "rejects non-local host values before invoking mix" do
      ctx = fake_tools()

      {output, status} =
        run_script(ctx.env ++ [{"MUSE_BROWSER_SMOKE_HOST", "example.com"}])

      assert status == 1
      assert output =~ "invalid MUSE_BROWSER_SMOKE_HOST 'example.com'"
      assert output =~ "use 127.0.0.1, localhost, or 0.0.0.0"
      assert read_optional(ctx.mix_calls) == ""
    end

    test "refuses to pass against a stale server already responding on the port" do
      ctx = fake_tools()

      {output, status} =
        run_script(
          ctx.env ++
            [
              {"FAKE_CURL_MODE", "stale"},
              {"MUSE_BROWSER_SMOKE_PORT", "4211"},
              {"MUSE_BROWSER_SMOKE_TIMEOUT", "2"}
            ]
        )

      assert status == 1
      assert output =~ "http://127.0.0.1:4211/ already responds before this script launched Muse"
      assert output =~ "Stop the stale server or choose a free MUSE_BROWSER_SMOKE_PORT"
      assert read_optional(ctx.mix_calls) == ""
      assert String.trim(File.read!(ctx.curl_calls)) == "1"
    end

    test "fails quickly and prints server logs when the launched server exits before readiness" do
      ctx = fake_tools()

      {output, status} =
        run_script(
          ctx.env ++
            [
              {"FAKE_CURL_MODE", "never"},
              {"FAKE_MIX_MUSE_MODE", "exit"},
              {"MUSE_BROWSER_SMOKE_PORT", "4212"},
              {"MUSE_BROWSER_SMOKE_TIMEOUT", "3"}
            ]
        )

      assert status == 1
      assert output =~ "Muse server exited before readiness"
      assert output =~ "fake bind failure: address already in use"

      mix_calls = File.read!(ctx.mix_calls)
      assert mix_calls =~ "compile"
      assert mix_calls =~ "muse --web-only --host 127.0.0.1 --port 4212 --no-watch"
      refute mix_calls =~ "muse.smoke"
    end

    test "passes validated host and port to both the server and HTTP assertions" do
      ctx = fake_tools()

      {output, status} =
        run_script(
          ctx.env ++
            [
              {"FAKE_CURL_MODE", "ready_after_preflight"},
              {"MUSE_BROWSER_SMOKE_HOST", "localhost"},
              {"MUSE_BROWSER_SMOKE_PORT", "4213"},
              {"MUSE_BROWSER_SMOKE_TIMEOUT", "2"}
            ],
          10_000
        )

      assert status == 0
      assert output =~ "LiveView browser smoke complete"

      mix_calls = File.read!(ctx.mix_calls)
      assert mix_calls =~ "compile"
      assert mix_calls =~ "muse --web-only --host localhost --port 4213 --no-watch"
      assert mix_calls =~ "muse.smoke --port 4213 --host localhost"
      assert File.read!(ctx.smoke_args) =~ "muse.smoke --port 4213 --host localhost"
    end
  end

  defp fake_tools do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "muse-liveview-smoke-test-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(fake_bin)

    mix_calls = Path.join(tmp_dir, "mix-calls.log")
    smoke_args = Path.join(tmp_dir, "smoke-args.log")
    curl_calls = Path.join(tmp_dir, "curl-count.log")
    curl_args = Path.join(tmp_dir, "curl-args.log")

    write_executable(Path.join(fake_bin, "mix"), fake_mix_script())
    write_executable(Path.join(fake_bin, "curl"), fake_curl_script())

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{
      env: [
        {"PATH", fake_bin <> ":" <> (System.get_env("PATH") || "")},
        {"MIX_CALLS", mix_calls},
        {"SMOKE_ARGS", smoke_args},
        {"CURL_CALLS", curl_calls},
        {"CURL_ARGS", curl_args}
      ],
      mix_calls: mix_calls,
      smoke_args: smoke_args,
      curl_calls: curl_calls,
      curl_args: curl_args
    }
  end

  defp run_script(env, timeout_ms \\ 7_000) do
    task =
      Task.async(fn ->
        System.cmd("bash", [@script], env: env, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> flunk("script/liveview-browser-smoke timed out after #{timeout_ms}ms")
    end
  end

  defp write_executable(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp read_optional(path) do
    if File.exists?(path), do: File.read!(path), else: ""
  end

  defp fake_mix_script do
    """
    #!/usr/bin/env bash
    set -euo pipefail

    echo "$*" >> "${MIX_CALLS}"

    case "${1:-}" in
      compile)
        echo "fake compile"
        exit 0
        ;;
      muse)
        case "${FAKE_MIX_MUSE_MODE:-sleep}" in
          exit)
            echo "fake bind failure: address already in use"
            exit 42
            ;;
          sleep)
            echo "fake server started"
            while true; do
              sleep 1
            done
            ;;
          *)
            echo "unexpected FAKE_MIX_MUSE_MODE=${FAKE_MIX_MUSE_MODE}" >&2
            exit 99
            ;;
        esac
        ;;
      muse.smoke)
        echo "$*" > "${SMOKE_ARGS}"
        echo "fake smoke assertions"
        exit 0
        ;;
      *)
        echo "unexpected mix command: $*" >&2
        exit 99
        ;;
    esac
    """
  end

  defp fake_curl_script do
    """
    #!/usr/bin/env bash
    set -euo pipefail

    count=0
    if [ -f "${CURL_CALLS}" ]; then
      count="$(cat "${CURL_CALLS}")"
    fi
    count=$((count + 1))
    echo "${count}" > "${CURL_CALLS}"
    echo "$*" >> "${CURL_ARGS}"

    case "${FAKE_CURL_MODE:-ready_after_preflight}" in
      stale)
        exit 0
        ;;
      never)
        exit 7
        ;;
      ready_after_preflight)
        if [ "${count}" -ge 2 ]; then
          echo '<div data-slash-commands></div>'
          exit 0
        fi
        exit 7
        ;;
      *)
        echo "unexpected FAKE_CURL_MODE=${FAKE_CURL_MODE}" >&2
        exit 2
        ;;
    esac
    """
  end
end
