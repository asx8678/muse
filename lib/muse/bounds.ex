defmodule Muse.Bounds do
  @moduledoc """
  Centralized, configurable memory caps for per-session events, command
  history, toasts, streaming buffers, and diagnostics.

  All caps are read from application environment (`:muse, :bounds`) so
  operators can tune them at deploy time.  Every public function falls back
  to a conservative compiled-in default, guaranteeing safety even when no
  config is present.

  ## App-env structure

      config :muse, :bounds, %{
        session_events: 2_000,
        command_history: 100,
        toasts: 20,
        streaming_buffer_bytes: 512_000,
        diagnostics: 100
      }

  A **map** is preferred over a keyword list so individual keys can be
  overridden without disturbing the others:

      config :muse, :bounds, %{toasts: 10}

  Merge semantics: the env value is `Map.merge/2`-ed over the defaults,
  so only explicitly-set keys win.
  """

  # -- Compiled-in defaults (conservative) ------------------------------------

  @default_session_events 2_000
  @default_command_history 100
  @default_toasts 20
  @default_streaming_buffer_bytes 512_000
  @default_diagnostics 100

  @defaults %{
    session_events: @default_session_events,
    command_history: @default_command_history,
    toasts: @default_toasts,
    streaming_buffer_bytes: @default_streaming_buffer_bytes,
    diagnostics: @default_diagnostics
  }

  # -- Public API -------------------------------------------------------------

  @doc "Maximum events retained per session (SessionServer state.events)."
  @spec session_events() :: pos_integer()
  def session_events, do: resolve(:session_events)

  @doc "Maximum command-history entries in HomeLive."
  @spec command_history() :: pos_integer()
  def command_history, do: resolve(:command_history)

  @doc "Maximum concurrent toasts in HomeLive."
  @spec toasts() :: pos_integer()
  def toasts, do: resolve(:toasts)

  @doc """
  Maximum byte size of a single streaming buffer (per turn_id).

  When a streaming buffer exceeds this limit, the oldest chunk text is
  truncated to keep the buffer at or below the cap, preserving the tail
  (most recent) content.
  """
  @spec streaming_buffer_bytes() :: pos_integer()
  def streaming_buffer_bytes, do: resolve(:streaming_buffer_bytes)

  @doc "Maximum diagnostics entries in HomeLive."
  @spec diagnostics() :: pos_integer()
  def diagnostics, do: resolve(:diagnostics)

  @doc "Returns all current bounds as a map (useful for diagnostics/telemetry)."
  @spec all() :: map()
  def all, do: Map.merge(@defaults, env_overrides())

  @doc """
  Trims a list to at most `count` items, keeping the **newest** (last)
  elements.  Returns the list unchanged if it is already within bounds.

  This is the canonical trimming helper so every bounded collection
  uses the same policy: drop oldest first.
  """
  @spec trim_newest_first(list(), pos_integer()) :: list()
  def trim_newest_first(list, count) when is_list(list) and is_integer(count) and count > 0 do
    len = length(list)

    if len > count do
      Enum.take(list, -count)
    else
      list
    end
  end

  @doc """
  Trims a streaming buffer string to at most `max_bytes` bytes, keeping
  the **tail** (most recent content) and dropping the oldest prefix.

  Binary splitting at arbitrary byte offsets can break multi-byte UTF-8
  code-points.  This function walks backward to the previous code-point
  boundary so the result is always valid UTF-8.
  """
  @spec trim_streaming_buffer(binary(), pos_integer()) :: binary()
  def trim_streaming_buffer(buffer, max_bytes)
      when is_binary(buffer) and is_integer(max_bytes) and max_bytes > 0 do
    if byte_size(buffer) <= max_bytes do
      buffer
    else
      # Take the last max_bytes bytes, then walk forward past any incomplete
      # UTF-8 continuation bytes so we start on a clean code-point.
      candidate = binary_part(buffer, byte_size(buffer) - max_bytes, max_bytes)
      walk_utf8_start(candidate)
    end
  end

  # -- Private ----------------------------------------------------------------

  defp resolve(key) when is_atom(key) do
    Map.get(env_overrides(), key, Map.get(@defaults, key))
  end

  defp env_overrides do
    case Application.get_env(:muse, :bounds) do
      overrides when is_map(overrides) ->
        overrides
        |> Map.take(Map.keys(@defaults))
        |> Map.filter(fn {_key, value} -> is_integer(value) and value > 0 end)

      _ ->
        %{}
    end
  end

  # Walk past leading UTF-8 continuation bytes (10xxxxxx, 0x80–0xBF)
  # to find the first valid start byte.  This ensures the truncated buffer
  # begins on a code-point boundary.  Returns the remaining string
  # including the start byte.
  defp walk_utf8_start(<<1::1, 0::1, _::6, rest::binary>>), do: walk_utf8_start(rest)

  defp walk_utf8_start(<<_::8, _::binary>> = str), do: str

  defp walk_utf8_start(""), do: ""
end
