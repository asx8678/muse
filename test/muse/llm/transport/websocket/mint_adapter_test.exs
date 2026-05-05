defmodule Muse.LLM.Transport.WebSocket.MintAdapterTest do
  use ExUnit.Case, async: true

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
end
