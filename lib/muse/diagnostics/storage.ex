defmodule Muse.Diagnostics.Storage do
  @moduledoc """
  Persists diagnostics to timestamped JSON files for later review and
  automated fixing.

  Each time diagnostics are queued, they are appended to a file in
  `~/.muse/diagnostics/` named with the current date and time:

      ~/.muse/diagnostics/diagnostics-2025-01-15T10-30-00.json

  The file contains a JSON array of diagnostic objects with level,
  message, timestamp, and metadata.
  """

  @base_dir "~/.muse/diagnostics"

  @doc """
  Save a list of diagnostics to a timestamped file.

  Returns `{:ok, path}` on success or `{:error, reason}` on failure.
  """
  @spec save([Muse.Diagnostic.t()]) :: {:ok, String.t()} | {:error, term()}
  def save([]), do: {:error, :no_diagnostics}

  def save(diagnostics) when is_list(diagnostics) do
    with {:ok, dir} <- ensure_dir(),
         path = file_path(dir),
         {:ok, json} <- encode_diagnostics(diagnostics) do
      case File.write(path, json) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Save a single diagnostic to a timestamped file.
  """
  @spec save_one(Muse.Diagnostic.t()) :: {:ok, String.t()} | {:error, term()}
  def save_one(diagnostic) do
    save([diagnostic])
  end

  @doc """
  List all saved diagnostic files, newest first.
  """
  @spec list_files() :: [String.t()]
  def list_files do
    dir = Path.expand(@base_dir)

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.sort_by(&File.stat!(&1, time: :local).mtime, {:desc, DateTime})
    else
      []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp ensure_dir do
    dir = Path.expand(@base_dir)
    File.mkdir_p(dir)
    {:ok, dir}
  rescue
    e -> {:error, "Failed to create diagnostics directory: #{Exception.message(e)}"}
  catch
    _, reason -> {:error, "Failed to create diagnostics directory: #{inspect(reason)}"}
  end

  defp file_path(dir) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601()
      |> String.replace(":", "-")
      |> String.replace(".", "-")

    Path.join(dir, "diagnostics-#{timestamp}.json")
  end

  defp encode_diagnostics(diagnostics) do
    payload =
      diagnostics
      |> Enum.map(fn d ->
        %{
          id: d.id,
          timestamp: format_timestamp(d.timestamp),
          level: d.level,
          message: d.message,
          metadata: d.metadata
        }
      end)
      |> then(fn entries -> %{saved_at: format_timestamp(DateTime.utc_now()), diagnostics: entries} end)

    Jason.encode(payload, pretty: true)
  rescue
    e -> {:error, "Failed to encode diagnostics: #{Exception.message(e)}"}
  catch
    _, reason -> {:error, "Failed to encode diagnostics: #{inspect(reason)}"}
  end

  defp format_timestamp(%DateTime{} = dt) do
    dt |> DateTime.to_iso8601()
  end

  defp format_timestamp(_), do: nil
end
