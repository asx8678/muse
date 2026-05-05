defmodule Muse.LLM.Transport.WebSocket.MintAdapter do
  @moduledoc """
  WebSocket client adapter backed by `Mint.WebSocket`.

  Implements the `connect/2`, `send_frame/3`, and `recv/2` callbacks
  expected by `Muse.LLM.Transport.WebSocket.Stream.default_stream/3` when
  configured as the `:websocket_client`.

  ## Configuration

  This adapter is not active by default. Enable it via application config:

      config :muse, :websocket_client, Muse.LLM.Transport.WebSocket.MintAdapter

  When unconfigured (the default in dev/test), `default_stream/3` returns
  `{:error, {:transport_error, :websocket_client_not_configured}}` and
  performs no network work.

  ## Connection state

  The adapter threads a `%__MODULE__{}` struct through `connect` → `send_frame`
  → `recv`. The struct holds:

    * `conn` — the `Mint.HTTP` connection
    * `websocket` — the `Mint.WebSocket` state
    * `ref` — the request reference for the WebSocket upgrade
    * `frame_buffer` — decoded frames awaiting delivery when a single
      `recv` call produces multiple frames

  Errors are returned as plain terms (atoms or `{tag, ...}` tuples) that
  `SafeError` can summarize. This adapter never leaks Authorization headers,
  create_frame payloads, or raw URL secrets in its error values.
  """

  alias Mint.HTTP
  alias Mint.WebSocket

  @enforce_keys [:conn, :websocket, :ref]
  defstruct [:conn, :websocket, :ref, frame_buffer: []]

  @type t :: %__MODULE__{
          conn: HTTP.t(),
          websocket: WebSocket.t(),
          ref: HTTP.request_ref(),
          frame_buffer: [WebSocket.frame()]
        }

  @doc """
  Opens a WebSocket connection to `url`.

  `opts` may include:

    * `:headers` — list of `{name, value}` tuples forwarded in the upgrade
      request.
    * `:timeout_ms` — connect timeout (ms), also forwarded as
      `connect_options: [timeout: ...]`.
    * `:connect_options` — forwarded to `Mint.HTTP.connect/4`.

  Returns `{:ok, %__MODULE__{}}` on success or `{:error, reason}` on failure.
  """
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(url, opts) when is_binary(url) and is_list(opts) do
    with {:ok, uri} <- parse_ws_url(url),
         {:ok, conn} <- mint_connect(uri, opts),
         {:ok, conn, ref} <- mint_upgrade(uri, conn, opts),
         {:ok, conn, websocket} <- await_upgrade(conn, ref, opts) do
      {:ok, %__MODULE__{conn: conn, websocket: websocket, ref: ref, frame_buffer: []}}
    end
  end

  @doc """
  Sends a single text frame containing `data` on the WebSocket connection.

  Returns `{:ok, updated_state}` on success or `{:error, reason}` on failure.
  """
  @spec send_frame(t(), iodata(), keyword()) :: {:ok, t()} | {:error, term()}
  def send_frame(%__MODULE__{} = state, data, _opts) do
    with {:ok, websocket, encoded} <- WebSocket.encode(state.websocket, {:text, data}),
         {:ok, conn} <- WebSocket.stream_request_body(state.conn, state.ref, encoded) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, _ws, error} ->
        {:error, error}

      {:error, conn, error, _responses} ->
        _ = HTTP.close(conn)
        {:error, error}
    end
  end

  @doc """
  Receives the next WebSocket frame (blocking).

  If a previous `recv` call produced multiple decoded frames, the buffered
  frames are returned first (LIFO pop). When the buffer is empty, this
  function blocks reading from the socket until a frame arrives or the
  timeout expires.

  Returns:

    * `{:ok, frame, updated_state}` — a decoded frame
    * `{:error, :timeout}` — no data within the receive timeout
    * `{:error, reason}` — a transport or protocol error
  """
  @spec recv(t(), keyword()) ::
          {:ok, WebSocket.frame() | term(), t()} | {:error, term()}
  def recv(%__MODULE__{frame_buffer: [frame | rest]} = state, _opts) do
    {:ok, frame, %{state | frame_buffer: rest}}
  end

  def recv(%__MODULE__{} = state, opts) do
    timeout = Keyword.get(opts, :receive_timeout, 30_000)

    case WebSocket.recv(state.conn, 0, timeout) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        decode_responses(state, responses)

      {:error, _conn, reason, _responses} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_ws_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port, path: path}
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        path = if path in [nil, ""], do: "/", else: path
        ws_scheme = String.to_atom(scheme)
        {:ok, %{scheme: ws_scheme, host: host, port: port, path: path}}

      _uri ->
        {:error, :invalid_websocket_url}
    end
  end

  defp mint_connect(uri, opts) do
    http_scheme = if uri.scheme == :wss, do: :https, else: :http
    connect_opts = build_connect_opts(opts)

    case HTTP.connect(http_scheme, uri.host, uri.port, connect_opts) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_connect_opts(opts) do
    base = [mode: :passive]

    base =
      case Keyword.get(opts, :timeout_ms) do
        timeout when is_integer(timeout) and timeout > 0 ->
          Keyword.put(base, :timeout, timeout)

        _ ->
          base
      end

    case Keyword.get(opts, :connect_options) do
      extra when is_list(extra) -> Keyword.merge(base, extra)
      _ -> base
    end
  end

  defp mint_upgrade(uri, conn, opts) do
    headers = Keyword.get(opts, :headers, [])

    case WebSocket.upgrade(uri.scheme, conn, uri.path, headers) do
      {:ok, conn, ref} -> {:ok, conn, ref}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp await_upgrade(conn, ref, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)

    with {:ok, conn, responses} <- recv_upgrade_response(conn, timeout) do
      case extract_upgrade_response(responses, ref) do
        {:ok, status, resp_headers} ->
          case WebSocket.new(conn, ref, status, resp_headers, mode: :passive) do
            {:ok, conn, websocket} -> {:ok, conn, websocket}
            {:error, _conn, reason} -> {:error, reason}
          end

        :error ->
          {:error, :websocket_upgrade_failed}
      end
    end
  end

  defp recv_upgrade_response(conn, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    recv_upgrade_response_loop(conn, deadline)
  end

  defp recv_upgrade_response_loop(conn, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case HTTP.recv(conn, 0, remaining) do
      {:ok, conn, responses} ->
        if upgrade_complete?(responses) do
          {:ok, conn, responses}
        else
          recv_upgrade_response_loop(conn, deadline)
        end

      {:error, _conn, reason, _responses} ->
        {:error, reason}
    end
  end

  defp upgrade_complete?(responses) do
    Enum.any?(responses, fn
      {:done, _ref} -> true
      _ -> false
    end)
  end

  defp extract_upgrade_response(responses, ref) do
    status =
      Enum.find_value(responses, fn
        {:status, ^ref, s} -> s
        _ -> nil
      end)

    headers =
      Enum.find_value(responses, fn
        {:headers, ^ref, h} -> h
        _ -> nil
      end)

    if status != nil and headers != nil do
      {:ok, status, headers}
    else
      :error
    end
  end

  defp decode_responses(state, responses) do
    {frames, websocket} =
      Enum.reduce(responses, {[], state.websocket}, fn
        {:data, _ref, data}, {acc_frames, ws} ->
          case WebSocket.decode(ws, data) do
            {:ok, new_ws, decoded} -> {acc_frames ++ decoded, new_ws}
            {:error, new_ws, _reason} -> {acc_frames, new_ws}
          end

        _other, acc ->
          acc
      end)

    # Filter out ping/pong control frames (handled by the transport layer)
    frames =
      Enum.reject(frames, fn
        {:ping, _} -> true
        {:pong, _} -> true
        _ -> false
      end)

    case frames do
      [] ->
        # No actionable frames; try receiving again
        recv(
          %{state | websocket: websocket},
          receive_timeout: resolve_receive_timeout(state)
        )

      [frame | rest] ->
        {:ok, frame, %{state | websocket: websocket, frame_buffer: rest}}
    end
  end

  defp resolve_receive_timeout(_state) do
    30_000
  end
end
