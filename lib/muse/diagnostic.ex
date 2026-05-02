defmodule Muse.Diagnostic do
  @moduledoc """
  Immutable backend diagnostic record surfaced in the Muse UI.

  Diagnostics represent warnings and failures that should be visible outside
  the terminal.  They are intentionally small and bounded so a noisy backend
  cannot flood the LiveView process with huge terms.
  """

  @enforce_keys [:id, :timestamp, :level, :message, :metadata]
  defstruct [:id, :timestamp, :level, :message, :metadata]

  @type level :: :warning | :error | :critical

  @type t :: %__MODULE__{
          id: pos_integer(),
          timestamp: DateTime.t(),
          level: level(),
          message: String.t(),
          metadata: map()
        }

  @max_message_chars 2_000
  @max_metadata_chars 2_000
  @inspect_limit 50

  @doc """
  Builds a new diagnostic.

  Accepted levels are `:warning`, `:error`, and `:critical`; `:warn` is
  normalized to `:warning`. Unsupported levels raise `ArgumentError` so callers
  fail consistently and early.
  """
  @spec new(atom(), term(), term()) :: t()
  def new(level, message, metadata \\ %{}) do
    %__MODULE__{
      id: generate_id(),
      timestamp: DateTime.utc_now(),
      level: normalize_level!(level),
      message: message |> safe_to_string() |> strip_ansi() |> truncate(@max_message_chars),
      metadata: normalize_metadata(metadata)
    }
  end

  defp normalize_level!(:warn), do: :warning
  defp normalize_level!(:warning), do: :warning
  defp normalize_level!(:error), do: :error
  defp normalize_level!(:critical), do: :critical

  defp normalize_level!(level) do
    raise ArgumentError,
          "unsupported diagnostic level #{inspect(level)}; expected :warning, :error, or :critical"
  end

  defp safe_to_string(term) when is_binary(term), do: term

  defp safe_to_string(term) do
    try do
      to_string(term)
    rescue
      _ -> safe_inspect(term)
    catch
      _, _ -> safe_inspect(term)
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata

  defp normalize_metadata(metadata) do
    %{metadata: metadata |> safe_inspect() |> truncate(@max_metadata_chars)}
  end

  defp safe_inspect(term) do
    inspect(term, limit: @inspect_limit, printable_limit: @max_metadata_chars)
  rescue
    _ -> "#Inspect.Error<uninspectable metadata>"
  catch
    _, _ -> "#Inspect.Error<uninspectable metadata>"
  end

  # Strips ANSI escape sequences (color codes, cursor control, etc.)
  # so diagnostics displayed in the UI are clean.
  defp strip_ansi(string) when is_binary(string) do
    String.replace(string, ~r/\e\[[0-9;]*[A-Za-z]/, "")
  end

  defp truncate(string, max_chars) do
    if String.length(string) > max_chars do
      String.slice(string, 0, max_chars)
    else
      string
    end
  end

  defp generate_id, do: System.unique_integer([:positive])
end
