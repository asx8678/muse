defmodule Muse.Weft.Channels.WatchChannelTest do
  use Muse.Weft.Test.ChannelCase, async: false

  alias Muse.Weft.Channels.WatchChannel
  alias Muse.Weft.Test.{FakeFileSystem, FakeWsTransport}

  setup do
    original_weft = Application.get_env(:muse, :weft)
    Application.put_env(:muse, :weft, enabled_channels: ["watch"])
    WatchChannel.ensure_tables()
    Application.put_env(:muse, :weft_watch_file_system_module, FakeFileSystem)

    on_exit(fn ->
      if original_weft do
        Application.put_env(:muse, :weft, original_weft)
      else
        Application.delete_env(:muse, :weft)
      end

      Application.delete_env(:muse, :weft_watch_file_system_module)
    end)

    :ok
  end

  describe "join/3" do
    test "joins successfully with valid watch:test-ref topic" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("watch:test-ref")

      assert channel_socket.assigns.watch_ref == "test-ref"
      assert channel_socket.assigns.watch_paths == [File.cwd!()]
    end

    test "joins with explicit path from payload" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("watch:path-ref", "test-token-16chars-ok", nil, %{
                 "path" => "/tmp"
               })

      assert channel_socket.assigns.watch_ref == "path-ref"
      assert channel_socket.assigns.watch_paths == ["/tmp"]
    end

    test "rejects join with empty ref" do
      assert {:error, %{reason: "invalid_ref"}} = FakeWsTransport.join_channel("watch:")
    end

    test "rejects join with path traversal ref" do
      assert {:error, %{reason: "invalid_ref"}} =
               FakeWsTransport.join_channel("watch:../escape")
    end

    test "rejects join when watch channel is disabled" do
      Application.put_env(:muse, :weft, enabled_channels: [])

      assert {:error, %{reason: "watch_channel_disabled"}} =
               FakeWsTransport.join_channel("watch:disabled-test")
    end
  end

  describe "file system events" do
    test "pushes fs_event for modified file" do
      assert {:ok, _user_socket, _channel_socket} =
               FakeWsTransport.join_channel("watch:fs-test", "test-token-16chars-ok", nil, %{
                 "path" => "/tmp"
               })

      watcher_pid = get_watcher_pid("fs-test")
      FakeFileSystem.send_event(watcher_pid, "/tmp/foo.txt", [:modified])

      assert_push("fs_event", %{type: "modified", path: "/tmp/foo.txt"}, 500)
    end

    test "pushes renamed event for coalesce pair" do
      assert {:ok, _user_socket, _channel_socket} =
               FakeWsTransport.join_channel("watch:rename-test", "test-token-16chars-ok", nil, %{
                 "path" => "/tmp"
               })

      watcher_pid = get_watcher_pid("rename-test")

      # Emit a deleted event followed by a created event quickly
      FakeFileSystem.send_event(watcher_pid, "/tmp/old.txt", [:deleted])
      FakeFileSystem.send_event(watcher_pid, "/tmp/new.txt", [:created])

      assert_push("renamed", %{old_path: "/tmp/old.txt", new_path: "/tmp/new.txt"}, 500)
    end
  end

  describe "multiple subscribers" do
    test "share the same underlying watcher" do
      assert {:ok, _user_socket1, _channel_socket1} =
               FakeWsTransport.join_channel("watch:multi-test", "test-token-16chars-ok", nil, %{
                 "path" => "/tmp"
               })

      assert {:ok, _user_socket2, _channel_socket2} =
               FakeWsTransport.join_channel("watch:multi-test", "test-token-16chars-ok", nil, %{
                 "path" => "/tmp"
               })

      assert [{"multi-test", 2, _watchers}] = :ets.lookup(:weft_watch_sessions, "multi-test")
    end
  end

  describe "terminate/2" do
    test "cleans up watcher when last subscriber leaves" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("watch:term-test", "test-token-16chars-ok", nil, %{
                 "path" => "/tmp"
               })

      watcher_pid = get_watcher_pid("term-test")

      Process.unlink(channel_socket.channel_pid)
      close(channel_socket)

      Process.sleep(100)

      refute Process.alive?(watcher_pid)
      assert [] = :ets.lookup(:weft_watch_sessions, "term-test")
    end
  end

  describe "handle_in subscribe" do
    test "adds additional path to watch" do
      assert {:ok, _user_socket, channel_socket} =
               FakeWsTransport.join_channel("watch:sub-test", "test-token-16chars-ok", nil, %{
                 "path" => "/tmp"
               })

      ref = FakeWsTransport.push(channel_socket, "subscribe", %{"path" => "/home"})
      assert_reply(ref, :ok, %{ok: true, path: "/home"}, 500)

      # Both watchers should exist in ETS
      assert [{"sub-test", 1, watchers}] = :ets.lookup(:weft_watch_sessions, "sub-test")
      assert Map.has_key?(watchers, "/tmp")
      assert Map.has_key?(watchers, "/home")
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp get_watcher_pid(ref) do
    [{^ref, _count, watchers}] = :ets.lookup(:weft_watch_sessions, ref)
    [pid | _] = Map.values(watchers)
    pid
  end
end
