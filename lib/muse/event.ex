defmodule Muse.Event do
  @moduledoc """
  Immutable event record produced throughout the Muse system.

  Every event gets a unique monotonically-increasing integer ID and a UTC
  timestamp at creation time.  `source`, `type`, and `data` are caller-defined.
  """

  @enforce_keys [:id, :timestamp, :source, :type, :data]
  defstruct [:id, :timestamp, :source, :type, :data]

  @type t :: %__MODULE__{
          id: pos_integer(),
          timestamp: DateTime.t(),
          source: atom(),
          type: atom(),
          data: term()
        }

  @spec new(atom(), atom(), term()) :: t()
  def new(source, type, data) do
    %__MODULE__{
      id: generate_id(),
      timestamp: DateTime.utc_now(),
      source: source,
      type: type,
      data: data
    }
  end

  defp generate_id, do: System.unique_integer([:positive])
end
