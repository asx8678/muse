defmodule Muse.Weft.PhoenixV2 do
  @moduledoc """
  Phoenix V2 wire format encoding/decoding.

  Format: `[join_ref, ref, topic, event, payload]`

  Used for testing raw WebSocket message handling and for
  external clients that speak the wire protocol directly.

  ## Example

      msg = PhoenixV2.join("session:abc-123")
      json = PhoenixV2.encode(msg)
      {:ok, decoded} = PhoenixV2.decode(json)
  """

  defstruct [:join_ref, :ref, :topic, :event, :payload]

  @type t :: %__MODULE__{
          join_ref: String.t() | nil,
          ref: String.t() | nil,
          topic: String.t(),
          event: String.t(),
          payload: map()
        }

  @doc """
  Encode a Phoenix V2 message to JSON array string.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = msg) do
    Jason.encode!([
      msg.join_ref,
      msg.ref,
      msg.topic,
      msg.event,
      msg.payload
    ])
  end

  @doc """
  Decode a JSON array string into a Phoenix V2 message.
  """
  @spec decode(String.t()) :: {:ok, t()} | {:error, String.t()}
  def decode(json) when is_binary(json) do
    with {:ok, [join_ref, ref, topic, event, payload]} <- Jason.decode(json) do
      {:ok,
       %__MODULE__{
         join_ref: join_ref,
         ref: ref,
         topic: topic,
         event: event,
         payload: payload
       }}
    else
      {:ok, _} -> {:error, "expected 5-element array"}
      {:error, %Jason.DecodeError{} = e} -> {:error, "invalid JSON: #{Exception.message(e)}"}
    end
  end

  @doc """
  Build a phx_join message.
  """
  @spec join(String.t(), String.t(), map()) :: t()
  def join(topic, ref \\ "1", payload \\ %{}) do
    %__MODULE__{
      join_ref: ref,
      ref: ref,
      topic: topic,
      event: "phx_join",
      payload: payload
    }
  end

  @doc """
  Build a phx_leave message.
  """
  @spec leave(String.t(), String.t()) :: t()
  def leave(topic, ref \\ "1") do
    %__MODULE__{
      join_ref: ref,
      ref: ref,
      topic: topic,
      event: "phx_leave",
      payload: %{}
    }
  end

  @doc """
  Build a heartbeat message.
  """
  @spec heartbeat(String.t()) :: t()
  def heartbeat(ref \\ "1") do
    %__MODULE__{
      join_ref: nil,
      ref: ref,
      topic: "phoenix",
      event: "heartbeat",
      payload: %{}
    }
  end
end
