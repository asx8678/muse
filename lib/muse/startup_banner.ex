defmodule Muse.StartupBanner do
  @moduledoc """
  Pure-function banner formatter for Muse startup output.

  Outputs a single concise line summarizing version, workspace, web URL,
  UI mode, hot-reload status, and console log level.
  """

  @doc """
  Returns the one-line startup banner as a string.

  ## Examples

      iex> Muse.StartupBanner.format(workspace: "/tmp/proj", web?: true, host: "127.0.0.1", port: 4000, watch?: true, ui: :repl, logs: :warning) =~ "Muse"
      true

  """
  @spec format(keyword()) :: String.t()
  def format(opts) when is_list(opts) do
    version = version()
    workspace = Keyword.fetch!(opts, :workspace)
    web = Keyword.fetch!(opts, :web?)
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    watch? = Keyword.fetch!(opts, :watch?)
    ui = Keyword.fetch!(opts, :ui)
    logs = Keyword.fetch!(opts, :logs)

    web_part =
      if web do
        "web=http://#{host}:#{port}"
      else
        "web=off"
      end

    reload_part = if watch?, do: "reload=on", else: "reload=off"

    [
      "Muse #{version}",
      "workspace=#{workspace}",
      web_part,
      "ui=#{ui}",
      reload_part,
      "logs=#{logs}+"
    ]
    |> Enum.join(" ")
  end

  @doc """
  Writes the formatted banner to stdout via `IO.puts/1`.

  Thin IO shell — easy to swap or suppress in tests.
  """
  @spec io_puts(keyword()) :: :ok
  def io_puts(opts) do
    IO.puts(format(opts))
    :ok
  end

  # -- Helpers -----------------------------------------------------------------

  defp version do
    case Application.spec(:muse, :vsn) do
      vsn when is_binary(vsn) -> fallback_if_empty(vsn)
      vsn when is_list(vsn) -> vsn |> List.to_string() |> fallback_if_empty()
      _ -> "0.1.0"
    end
  rescue
    _ -> "0.1.0"
  catch
    _, _ -> "0.1.0"
  end

  defp fallback_if_empty(""), do: "0.1.0"
  defp fallback_if_empty(vsn), do: vsn
end
