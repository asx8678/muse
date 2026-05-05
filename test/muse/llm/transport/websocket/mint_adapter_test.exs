defmodule Muse.LLM.Transport.WebSocket.MintAdapterTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Muse.LLM.Transport.WebSocket.MintAdapter

  describe "module structure" do
    test "implements connect/2, send_frame/3, and recv/2 callbacks" do
      assert function_exported?(MintAdapter, :connect, 2)
      assert function_exported?(MintAdapter, :send_frame, 3)
      assert function_exported?(MintAdapter, :recv, 2)
    end

    test "struct has required fields" do
      state = %MintAdapter{conn: nil, websocket: nil, ref: nil, frame_buffer: []}
      assert state.conn == nil
      assert state.websocket == nil
      assert state.ref == nil
      assert state.frame_buffer == []
    end
  end

  describe "connect/2" do
    test "returns error for invalid URL" do
      assert {:error, :invalid_websocket_url} = MintAdapter.connect("http://not-websocket", [])
    end

    test "returns error for URL missing host" do
      assert {:error, :invalid_websocket_url} = MintAdapter.connect("ws://", [])
    end

    test "returns error for ws URL with empty host" do
      assert {:error, :invalid_websocket_url} = MintAdapter.connect("ws:///path", [])
    end

    test "rejects URL userinfo, query, and fragment before network work" do
      assert {:error, :websocket_url_contains_userinfo} =
               MintAdapter.connect("ws://user:secret@localhost/socket", [])

      assert {:error, :websocket_url_contains_query} =
               MintAdapter.connect("ws://localhost/socket?api_key=sk-secret", [])

      assert {:error, :websocket_url_contains_fragment} =
               MintAdapter.connect("ws://localhost/socket#token=sk-secret", [])
    end
  end

  describe "passive Mint.WebSocket lifecycle" do
    test "connects, sends, replies to ping, and buffers decoded frames" do
      {:ok, server} = start_ws_server([{:ping, "keepalive"}, {:text, "one"}, {:text, "two"}])

      assert {:ok, state} =
               MintAdapter.connect("ws://localhost:#{server.port}/socket", timeout_ms: 1_000)

      assert {:ok, state} = MintAdapter.send_frame(state, "response.create", [])

      assert {:ok, {:text, "one"}, state} = MintAdapter.recv(state, receive_timeout: 1_000)
      assert {:ok, {:text, "two"}, state} = MintAdapter.recv(state, receive_timeout: 1_000)
      assert state.frame_buffer == []

      assert_receive {:server_received, "response.create"}
      assert_receive {:server_received_pong, "keepalive"}
    end
  end

  describe "recv/2 with empty frame_buffer" do
    test "returns buffered frame first when frame_buffer is non-empty" do
      # Create a minimal state with buffered frames
      # We can't create a real Mint.WebSocket struct without a connection,
      # but we can test the buffer-pop logic with a mock struct
      state = %MintAdapter{
        conn: :fake_conn,
        websocket: :fake_ws,
        ref: :fake_ref,
        frame_buffer: [{:text, "buffered_frame"}, {:close, 1000, "done"}]
      }

      assert {:ok, {:text, "buffered_frame"}, new_state} =
               MintAdapter.recv(state, [])

      assert new_state.frame_buffer == [{:close, 1000, "done"}]
    end

    test "returns single buffered frame and empties buffer" do
      state = %MintAdapter{
        conn: :fake_conn,
        websocket: :fake_ws,
        ref: :fake_ref,
        frame_buffer: [{:close, 1000, "normal"}]
      }

      assert {:ok, {:close, 1000, "normal"}, new_state} =
               MintAdapter.recv(state, [])

      assert new_state.frame_buffer == []
    end
  end

  defp start_ws_server(outbound_frames) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        :ok = :gen_tcp.close(listen_socket)

        with {:ok, request} <- recv_http_upgrade(socket),
             {:ok, key} <- websocket_key(request),
             :ok <- send_http_upgrade(socket, key),
             {:ok, {:text, frame}} <- recv_client_frame(socket) do
          send(parent, {:server_received, frame})
          Enum.each(outbound_frames, &:gen_tcp.send(socket, encode_server_frame(&1)))

          case recv_client_frame(socket) do
            {:ok, {:pong, payload}} -> send(parent, {:server_received_pong, payload})
            _other -> :ok
          end
        end

        :gen_tcp.close(socket)
      end)

    {:ok, %{pid: pid, port: port}}
  end

  defp recv_http_upgrade(socket, acc \\ "") do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, data} -> recv_http_upgrade(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp websocket_key(request) do
    request
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == "sec-websocket-key" do
            {:ok, String.trim(value)}
          end

        _other ->
          nil
      end
    end)
    |> case do
      nil -> {:error, :missing_sec_websocket_key}
      result -> result
    end
  end

  defp send_http_upgrade(socket, key) do
    accept =
      :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      |> Base.encode64()

    response =
      [
        "HTTP/1.1 101 Switching Protocols\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Accept: ",
        accept,
        "\r\n\r\n"
      ]

    :gen_tcp.send(socket, response)
  end

  defp recv_client_frame(socket) do
    with {:ok, <<fin::1, _reserved::3, opcode::4, masked::1, length_code::7>>} <-
           :gen_tcp.recv(socket, 2, 1_000),
         {:ok, payload_length} <- recv_payload_length(socket, length_code),
         {:ok, mask_key} when masked == 1 <- :gen_tcp.recv(socket, 4, 1_000),
         {:ok, masked_payload} <- :gen_tcp.recv(socket, payload_length, 1_000) do
      payload = unmask(masked_payload, mask_key)
      {:ok, {client_opcode(opcode, fin), payload}}
    end
  end

  defp recv_payload_length(_socket, length) when length < 126, do: {:ok, length}

  defp recv_payload_length(socket, 126) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, 1_000), do: {:ok, length}
  end

  defp recv_payload_length(socket, 127) do
    with {:ok, <<length::64>>} <- :gen_tcp.recv(socket, 8, 1_000), do: {:ok, length}
  end

  defp unmask(payload, mask_key) do
    mask_bytes = :binary.bin_to_list(mask_key)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> bxor(byte, Enum.at(mask_bytes, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end

  defp client_opcode(1, 1), do: :text
  defp client_opcode(2, 1), do: :binary
  defp client_opcode(8, 1), do: :close
  defp client_opcode(9, 1), do: :ping
  defp client_opcode(10, 1), do: :pong
  defp client_opcode(opcode, _fin), do: {:opcode, opcode}

  defp encode_server_frame({:text, payload}), do: encode_server_frame(1, payload)
  defp encode_server_frame({:ping, payload}), do: encode_server_frame(9, payload)
  defp encode_server_frame({:pong, payload}), do: encode_server_frame(10, payload)

  defp encode_server_frame({:close, code, reason}),
    do: encode_server_frame(8, <<code::16, reason::binary>>)

  defp encode_server_frame(opcode, payload) do
    payload = IO.iodata_to_binary(payload)
    length = byte_size(payload)

    cond do
      length < 126 -> <<1::1, 0::3, opcode::4, 0::1, length::7, payload::binary>>
      length < 65_536 -> <<1::1, 0::3, opcode::4, 0::1, 126::7, length::16, payload::binary>>
      true -> <<1::1, 0::3, opcode::4, 0::1, 127::7, length::64, payload::binary>>
    end
  end
end
