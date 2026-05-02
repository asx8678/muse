defmodule Muse.StartupBanner do
  @moduledoc """
  Pure-function banner formatter for Muse startup output.

  Step 11 (full Application supervisor wiring) will call `format/1` and
  `io_puts/1` at the end of boot.  Keeping formatting separate from IO
  makes it trivial to unit-test every permutation without starting
  supervisors.
  """

  alias Muse.BootOptions

  @doc """
  Returns the multi-line startup banner as a string.

  Accepts either a `%Muse.BootOptions{}` struct or a keyword list with
  the same keys (useful when BootOptions isn't available yet).

  ## Examples

      iex> Muse.StartupBanner.format(workspace: "/tmp/proj", cli?: true, web?: true, host: "127.0.0.1", port: 4000, watch?: true) =~ "Muse started"
      true

  """
  @spec format(BootOptions.t() | keyword()) :: String.t()
  def format(opts) when is_struct(opts, BootOptions), do: do_format(opts)

  def format(opts) when is_list(opts) do
    struct!(BootOptions, opts) |> do_format()
  end

  defp do_format(opts) do
    lines = [
      "Muse started",
      "Workspace: #{opts.workspace}",
      "CLI: #{enabled(opts.cli?)}",
      web_line(opts),
      "Hot reload: #{enabled(opts.watch?)}"
    ]

    Enum.join(lines, "\n")
  end

  defp web_line(%{web?: false}), do: "Web: disabled"

  defp web_line(%{web?: true, host: host, port: port}) do
    "Web: http://#{host}:#{port}"
  end

  defp enabled(true), do: "enabled"
  defp enabled(false), do: "disabled"

  @doc """
  Writes the formatted banner to stdout via `IO.puts/1`.

  Thin IO shell — easy to swap or suppress in tests.
  """
  @spec io_puts(BootOptions.t() | keyword()) :: :ok
  def io_puts(opts) do
    IO.puts(format(opts))
    :ok
  end
end
