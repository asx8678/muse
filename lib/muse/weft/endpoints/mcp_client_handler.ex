defmodule Muse.Weft.Endpoints.McpClientHandler do
  @moduledoc """
  HTTP POST handler for the MCP JSON-RPC bridge.

  Receives JSON-RPC requests from external MCP clients over HTTP,
  forwards them to the browser via the `McpChannel` WebSocket,
  and returns the browser's response (or an error) back to the
  HTTP client.

  ## Route

      POST /socket/mcp-remote-client?sessionId=<id>&token=<token>

  ## Authentication

  Uses `MuseWeb.ExternalSocketAuth` with the same token model as the
  external WebSocket — the `token` query parameter is hashed and
  compared against configured token hashes.

  ## Opt-in

  The handler is active only when MCP is enabled in config:

      config :muse, :weft, enabled_channels: ["mcp"]
  """

  @behaviour Plug

  import Plug.Conn

  alias Muse.Weft.ChannelSender
  alias Muse.Weft.Channels.McpChannel
  alias MuseWeb.ExternalEventFilter
  alias MuseWeb.ExternalSocketAuth

  @default_timeout 30_000

  @impl Plug
  def init(opts) do
    Keyword.put_new(opts, :timeout, @default_timeout)
  end

  @impl Plug
  def call(conn, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    if not mcp_enabled?() do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{"error" => "MCP channel disabled"}))
      |> halt()
    else
      conn = fetch_query_params(conn)

      with {:ok, conn} <- authenticate(conn),
           {:ok, conn, session_id} <- validate_session(conn),
           {:ok, body, conn} <- read_request_body(conn),
           {:ok, parsed} <- parse_json(body),
           :ok <- validate_jsonrpc(parsed) do
        handle_message(conn, session_id, parsed, timeout)
      else
        {:error, :unauthorized} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
          |> halt()

        {:error, :not_connected} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            404,
            Jason.encode!(jsonrpc_error(nil, -32_000, "Browser is not connected"))
          )
          |> halt()

        {:error, :bad_request, reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(reason))
          |> halt()

        {:error, :invalid_json} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(jsonrpc_error(nil, -32_700, "Parse error")))
          |> halt()
      end
    end
  end

  # -- Config ------------------------------------------------------------------

  defp mcp_enabled? do
    Application.get_env(:muse, :weft, [])
    |> Keyword.get(:enabled_channels, [])
    |> Enum.member?("mcp")
  end

  # -- Authentication ----------------------------------------------------------

  defp authenticate(conn) do
    token = conn.query_params["token"]

    case ExternalSocketAuth.authenticate(%{"token" => token}) do
      {:ok, _principal} -> {:ok, conn}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  # -- Session validation ------------------------------------------------------

  defp validate_session(conn) do
    session_id = conn.query_params["sessionId"]

    cond do
      is_nil(session_id) or session_id == "" ->
        {:error, :bad_request, jsonrpc_error(nil, -32_600, "Invalid Request: missing sessionId")}

      not ExternalEventFilter.valid_session_id?(session_id) ->
        {:error, :bad_request, jsonrpc_error(nil, -32_600, "Invalid Request: invalid sessionId")}

      true ->
        case McpChannel.lookup_sender(session_id) do
          {:ok, _sender} ->
            {:ok, conn, session_id}

          {:error, :not_connected} ->
            {:error, :not_connected}

          {:error, :disabled} ->
            {:error, :bad_request, jsonrpc_error(nil, -32_000, "MCP channel disabled")}
        end
    end
  end

  # -- Body parsing ------------------------------------------------------------

  defp read_request_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _data, _conn} -> {:error, :invalid_json}
      {:error, :timeout} -> {:error, :invalid_json}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp parse_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp validate_jsonrpc(body) when is_map(body) do
    if Map.has_key?(body, "jsonrpc") do
      :ok
    else
      {:error, :bad_request, jsonrpc_error(nil, -32_600, "Invalid Request")}
    end
  end

  defp validate_jsonrpc(_body) do
    {:error, :bad_request, jsonrpc_error(nil, -32_600, "Invalid Request")}
  end

  # -- Request handling --------------------------------------------------------

  defp handle_message(conn, session_id, %{"id" => id} = body, timeout)
       when not is_nil(id) do
    request_id = id
    from_pid = self()

    case McpChannel.register_awaiting_answer(session_id, request_id, from_pid) do
      {:ok, ref} ->
        {:ok, sender} = McpChannel.lookup_sender(session_id)
        ChannelSender.push(sender, "mcp_message", body)

        receive do
          {:mcp_response, payload} ->
            Process.demonitor(ref, [:flush])

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(payload))
            |> halt()

          {:DOWN, ^ref, :process, _pid, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              500,
              Jason.encode!(
                jsonrpc_error(
                  request_id,
                  -32_603,
                  "Internal error: channel process died (#{inspect(reason)})"
                )
              )
            )
            |> halt()

          {:mcp_error, reason} ->
            Process.demonitor(ref, [:flush])

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              500,
              Jason.encode!(jsonrpc_error(request_id, -32_603, "Internal error: #{reason}"))
            )
            |> halt()
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            McpChannel.consume_awaiting_answer(session_id, request_id)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              504,
              Jason.encode!(
                jsonrpc_error(
                  request_id,
                  -32_003,
                  "Timeout waiting for browser response"
                )
              )
            )
            |> halt()
        end

      {:error, :not_connected} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(jsonrpc_error(request_id, -32_000, "Browser is not connected"))
        )
        |> halt()

      {:error, :disabled} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{"error" => "MCP channel disabled"}))
        |> halt()
    end
  end

  defp handle_message(conn, session_id, body, _timeout) do
    case McpChannel.lookup_sender(session_id) do
      {:ok, sender} ->
        ChannelSender.push(sender, "mcp_message", body)

        conn
        |> send_resp(202, "")
        |> halt()

      {:error, :not_connected} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(jsonrpc_error(nil, -32_000, "Browser is not connected"))
        )
        |> halt()

      {:error, :disabled} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{"error" => "MCP channel disabled"}))
        |> halt()
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp jsonrpc_error(id, code, message) do
    base = %{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => code,
        "message" => message
      }
    }

    if is_nil(id) do
      base
    else
      Map.put(base, "id", id)
    end
  end
end
