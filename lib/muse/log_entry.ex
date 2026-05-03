defmodule Muse.LogEntry do
  @moduledoc """
  Immutable log entry record for the Muse structured log buffer.

  Every entry gets a unique monotonically-increasing integer ID and a UTC
  timestamp at creation time. `level`, `source`, `message`, and `metadata`
  are caller-defined.
  """

  @enforce_keys [:id, :timestamp, :level, :source, :message]
  defstruct [:id, :timestamp, :level, :source, :message, metadata: %{}]

  @type level :: :debug | :info | :warning | :error | :critical
  @type source :: atom()

  @type t :: %__MODULE__{
          id: pos_integer(),
          timestamp: DateTime.t(),
          level: level(),
          source: source(),
          message: String.t(),
          metadata: map()
        }

  @spec new(level(), String.t(), map(), source()) :: t()
  def new(level, message, metadata \\ %{}, source \\ :app) do
    %__MODULE__{
      id: generate_id(),
      timestamp: DateTime.utc_now(),
      level: normalize_level(level),
      source: source,
      message: to_string(message),
      metadata: metadata
    }
  end

  defp generate_id, do: System.unique_integer([:positive])

  defp normalize_level(:warn), do: :warning
  defp normalize_level(level) when level in ~w(debug info warning error critical)a, do: level
  defp normalize_level(level) when is_atom(level), do: :info
  defp normalize_level(_), do: :info
end
