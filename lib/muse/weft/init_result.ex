defmodule Muse.Weft.InitResult do
  @moduledoc """
  Channel initialization result.

  - `:done` — clean exit, phx_close sent
  - `{:error, reason}` — join validation failure, phx_reply error sent
  - `{:shutdown, reason}` — runtime error, phx_error sent (triggers client rejoin)
  """

  @type t :: :done | {:error, String.t()} | {:shutdown, String.t()}
end
