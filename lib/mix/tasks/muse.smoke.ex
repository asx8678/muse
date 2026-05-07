defmodule Mix.Tasks.Muse.Smoke do
  @shortdoc "Run LiveView browser smoke assertions against a running Muse server"

  @moduledoc """
  Runs HTTP-based smoke assertions against a running Muse server.

  This task does NOT start the Muse application. It assumes a Muse server
  is already running and accessible at the specified host:port.

  ## Usage

      mix muse.smoke [--port PORT] [--host HOST]

  ## Options

    * `--port`, `-p` — HTTP port (default: 4101)
    * `--host`       — HTTP host (default: 127.0.0.1)

  ## Prerequisites

  Start the Muse server first:

      MIX_ENV=smoke mix muse --web-only --port 4101 --no-watch

  Or use the orchestration script:

      ./script/liveview-browser-smoke

  ## What it checks

    1. Home page loads (HTTP 200 with substantial HTML body)
    2. Accessibility markers — ARIA roles, labels, live regions on
       chat panel, context panel, toast container, and composer
    3. Command discoverability — /help hints, slash-commands data
       attribute, placeholder text, and descriptive ARIA labels
    4. Session/status/context panel markers — complementary role,
       session labels, workspace context labels
    5. No visible secrets — no API key prefixes (sk-), Bearer tokens,
       or key/env-var names leaked into rendered HTML
    6. Keyboard focus indicators — visible labels, aria-describedby,
       form roles, submit buttons, screen-reader-only utility class

  This task does NOT verify browser console errors — that requires a
  real browser (Playwright/QA Kitten). See `docs/testing.md` for the
  optional Playwright integration path.
  """

  use Mix.Task

  @default_host "127.0.0.1"
  @default_port 4101

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [port: :integer, host: :string],
        aliases: [p: :port]
      )

    host = opts[:host] || @default_host
    port = opts[:port] || @default_port
    base_url = "http://#{host}:#{port}"

    IO.puts("==> Running LiveView browser smoke against #{base_url}")

    checks = [
      {"Home page loads", fn -> check_home_loads(base_url) end},
      {"Accessibility markers present", fn -> check_accessibility_markers(base_url) end},
      {"Command discoverability", fn -> check_discoverability(base_url) end},
      {"Session/context panel markers", fn -> check_session_panel(base_url) end},
      {"No visible secrets", fn -> check_no_secrets(base_url) end},
      {"Keyboard focus indicators", fn -> check_focus_indicators(base_url) end}
    ]

    results =
      Enum.map(checks, fn {name, check_fn} ->
        case check_fn.() do
          :ok -> {name, :ok, nil}
          {:error, reason} -> {name, :error, reason}
        end
      end)

    passed = Enum.count(results, fn {_, status, _} -> status == :ok end)
    failed = Enum.count(results, fn {_, status, _} -> status == :error end)

    IO.puts("")
    IO.puts("==> Smoke results: #{passed} passed, #{failed} failed")
    IO.puts("")

    Enum.each(results, fn {name, status, reason} ->
      icon = if status == :ok, do: "✓", else: "✗"
      suffix = if reason, do: " — #{reason}", else: ""
      IO.puts("  #{icon} #{name}#{suffix}")
    end)

    if failed > 0 do
      IO.puts("")
      Mix.raise("Smoke checks failed: #{failed} check(s) did not pass")
    end

    IO.puts("")
    IO.puts("==> All smoke checks passed!")
    :ok
  end

  # -- Individual checks --------------------------------------------------------

  defp check_home_loads(base_url) do
    case fetch_html(base_url) do
      {:ok, html} ->
        if byte_size(html) > 100 do
          :ok
        else
          {:error, "page body too short (#{byte_size(html)} bytes)"}
        end

      {:error, reason} ->
        {:error, "connection failed: #{reason}. Is the Muse server running at #{base_url}/?"}
    end
  end

  defp check_accessibility_markers(base_url) do
    with {:ok, html} <- fetch_html(base_url) do
      checks = [
        {~s(role="region"), "chat panel region role"},
        {~s(aria-label="Muse conversation"), "chat panel ARIA label"},
        {~s(role="log"), "chat scroll log role"},
        {~s(aria-live="polite"), "ARIA live region"},
        {~s(role="complementary"), "context panel complementary role"},
        {~s(aria-label="Workspace context and session status"), "context panel ARIA label"},
        {~s(role="status"), "status ARIA role"},
        {~s(aria-label="Notifications"), "toast container ARIA label"}
      ]

      missing =
        Enum.reject(checks, fn {pattern, _desc} ->
          String.contains?(html, pattern)
        end)

      case missing do
        [] ->
          :ok

        _ ->
          {:error, "missing: #{Enum.map_join(missing, ", ", fn {_, d} -> d end)}"}
      end
    end
  end

  defp check_discoverability(base_url) do
    with {:ok, html} <- fetch_html(base_url) do
      checks = [
        {"/help", "/help hint visible"},
        {"data-slash-commands", "slash commands data attribute"},
        {"Ask Muse anything, or type /help", "chat placeholder text"},
        {~s(aria-label="Message to Muse"), "input ARIA label"},
        {~s(aria-label="Message composer"), "composer ARIA label"},
        {~s(aria-label="Send message to Muse"), "send button ARIA label"}
      ]

      missing =
        Enum.reject(checks, fn {pattern, _desc} ->
          String.contains?(html, pattern)
        end)

      case missing do
        [] ->
          :ok

        _ ->
          {:error, "missing: #{Enum.map_join(missing, ", ", fn {_, d} -> d end)}"}
      end
    end
  end

  defp check_session_panel(base_url) do
    with {:ok, html} <- fetch_html(base_url) do
      checks = [
        {"context-sidebar", "context sidebar element"},
        {"session", "session label or text"},
        {~s(role="complementary"), "complementary role on context panel"},
        {~s(aria-label="Workspace context and session status"),
         "context panel ARIA label for session status"}
      ]

      missing =
        Enum.reject(checks, fn {pattern, _desc} ->
          String.contains?(html, pattern)
        end)

      case missing do
        [] ->
          :ok

        _ ->
          {:error, "missing: #{Enum.map_join(missing, ", ", fn {_, d} -> d end)}"}
      end
    end
  end

  defp check_no_secrets(base_url) do
    with {:ok, html} <- fetch_html(base_url) do
      secret_patterns = [
        {"sk-", "OpenAI/Anthropic API key prefix"},
        {"sk_live_", "live API key prefix"},
        {"Bearer ", "bearer token prefix"},
        {"OPENAI_API_KEY", "env var name for OpenAI API key"},
        {"ANTHROPIC_API_KEY", "env var name for Anthropic API key"},
        {"secret_key_base", "secret key base reference"}
      ]

      found =
        Enum.filter(secret_patterns, fn {pattern, _desc} ->
          String.contains?(html, pattern)
        end)

      case found do
        [] ->
          :ok

        _ ->
          leaked = Enum.map_join(found, ", ", fn {p, d} -> "#{d} (#{inspect(p)})" end)
          {:error, "leaked secrets: #{leaked}"}
      end
    end
  end

  defp check_focus_indicators(base_url) do
    with {:ok, html} <- fetch_html(base_url) do
      checks = [
        {~s(<label for="chat-input-textarea"), "visible label on chat input"},
        {~s(placeholder="Ask Muse anything, or type /help..."),
         "concise placeholder on chat input"},
        {~s(role="form"), "form role on composer"},
        {~s(type="submit"), "submit button present"},
        {~s(aria-label="Collapse to rail"), "sidebar collapse button label"},
        {"sr-only", "screen-reader-only utility class"}
      ]

      missing =
        Enum.reject(checks, fn {pattern, _desc} ->
          String.contains?(html, pattern)
        end)

      case missing do
        [] ->
          :ok

        _ ->
          {:error, "missing: #{Enum.map_join(missing, ", ", fn {_, d} -> d end)}"}
      end
    end
  end

  # -- HTTP helper --------------------------------------------------------------

  defp fetch_html(base_url) do
    case Req.get(base_url,
           connect_options: [timeout: 5_000],
           receive_timeout: 10_000,
           redirect: false,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, %{reason: :econnrefused}} ->
        {:error, "connection refused"}

      {:error, reason} when is_exception(reason) ->
        {:error, Exception.message(reason)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
