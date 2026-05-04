defmodule Muse.Tools.ReadFile do
  @moduledoc """
  Read-only tool: read the contents of a text file in the workspace.

  Binary files are blocked. Supports line range selection.
  Secret and ignored paths are blocked. Output is capped.

  Uses bounded IO (`File.open` + `IO.binread`) to avoid reading
  arbitrarily large files into memory.

  ## Output format

      %{
        path: "lib/muse.ex",
        content: "...",
        lines: 42,
        start_line: 1,
        end_line: 42,
        truncated: false,
        metadata: %{byte_size: 1234}
      }
  """

  alias Muse.Tool.Result

  @default_max_lines 500
  @max_bytes 500_000
  # +1 byte to detect truncation without reading the entire file
  @read_ahead 1

  @doc """
  Execute the read_file tool.

  ## Arguments

    * `"path"` — relative file path within workspace (required)
    * `"start_line"` — first line to read (1-based)
    * `"end_line"` — last line to read (inclusive)
    * `"max_lines"` — max number of lines (default: 500)

  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = Map.fetch!(context, :workspace)

    with {:ok, path} <- require_path(args),
         {:ok, resolved} <- safe_resolve(path, workspace),
         :ok <- check_not_directory(resolved),
         {:ok, content, read_truncated} <- read_text(resolved),
         {:ok, lines} <- split_lines(content),
         {:ok, sliced, start_line, end_line} <- slice_lines(lines, args),
         {:ok, output, cap_truncated} <- cap_output(sliced) do
      Result.ok("read_file", %{
        path: path,
        content: output,
        lines: length(sliced),
        start_line: start_line,
        end_line: end_line,
        truncated: read_truncated or cap_truncated or length(lines) > length(sliced),
        metadata: %{byte_size: file_byte_size(resolved, content)}
      })
    else
      {:error, reason} ->
        Result.error("read_file", reason)
    end
  end

  defp require_path(args) do
    case Map.get(args, "path") do
      nil -> {:error, "path is required"}
      "" -> {:error, "path is required"}
      path when is_binary(path) -> {:ok, path}
      _ -> {:error, "path must be a string"}
    end
  end

  defp safe_resolve(path, workspace) do
    try do
      {:ok, Muse.Workspace.safe_resolve!(path, workspace, [])}
    rescue
      ArgumentError -> {:error, "path escapes workspace or violates safety rules"}
    end
  end

  defp check_not_directory(path) do
    if File.dir?(path) do
      {:error, "path is a directory, not a file"}
    else
      :ok
    end
  end

  # Bounded IO: read at most @max_bytes + 1, never the entire file
  defp read_text(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io_dev} ->
        try do
          data = IO.binread(io_dev, @max_bytes + @read_ahead)

          case data do
            {:error, reason} ->
              {:error, "file read error: #{inspect(reason)}"}

            :eof ->
              {:ok, "", false}

            bin when is_binary(bin) ->
              # Binary detection: check first 8KB for null bytes
              sample_size = min(byte_size(bin), 8192)
              <<sample::binary-size(sample_size), _::binary>> = bin

              if :binary.match(sample, <<0>>) != :nomatch do
                {:error, "binary files are not supported"}
              else
                truncated = byte_size(bin) > @max_bytes

                content =
                  if truncated do
                    # Use binary_part for safe truncation (no UTF-8 validation)
                    binary_part(bin, 0, @max_bytes)
                  else
                    bin
                  end

                {:ok, content, truncated}
              end
          end
        after
          File.close(io_dev)
        end

      {:error, :enoent} ->
        {:error, "file not found"}

      {:error, :eacces} ->
        {:error, "permission denied"}

      {:error, reason} ->
        {:error, "file read error: #{inspect(reason)}"}
    end
  end

  defp split_lines(content) do
    {:ok, String.split(content, "\n")}
  end

  defp slice_lines(lines, args) do
    total = length(lines)
    start_line = Map.get(args, "start_line", 1)
    max_lines = Map.get(args, "max_lines", @default_max_lines)

    # If start_line is past EOF, return empty content cleanly
    # (avoids descending-range warning from Enum.slice).
    if start_line > total do
      {:ok, [], start_line, start_line}
    else
      end_line =
        case Map.get(args, "end_line") do
          nil -> min(start_line + max_lines - 1, total)
          el -> min(el, total)
        end

      start_idx = max(start_line - 1, 0)
      end_idx = min(end_line, total)

      sliced = Enum.slice(lines, start_idx..(end_idx - 1))
      {:ok, sliced, start_line, end_line}
    end
  end

  defp cap_output(text_lines) do
    joined = Enum.join(text_lines, "\n")

    if byte_size(joined) > @max_bytes do
      # Use binary_part for safe truncation without UTF-8 boundary issues
      capped = binary_part(joined, 0, @max_bytes)
      {:ok, capped, true}
    else
      {:ok, joined, false}
    end
  end

  # Report actual file size via stat when available; fall back to content size
  defp file_byte_size(path, content) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> byte_size(content)
    end
  end
end
