defmodule MuseWeb.BrowserAccessControlTest do
  @moduledoc """
  Tests for the BrowserAccessControl plug.

  The plug is disabled in test environment via :browser_access_enforced=false,
  so we test the enforcement logic directly via enforce_local_only/1 and
  call/2 with enforcement temporarily enabled.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias MuseWeb.BrowserAccessControl

  setup do
    original_access = Application.get_env(:muse, :browser_access)
    original_enforced = Application.get_env(:muse, :browser_access_enforced)
    original_sys = System.get_env("MUSE_BROWSER_ACCESS")

    # Use :sentinel to distinguish "not set" from "set to false/nil"
    original_access_val = if original_access != nil, do: original_access, else: :sentinel
    original_enforced_val = if original_enforced != nil, do: original_enforced, else: :sentinel

    on_exit(fn ->
      case original_access_val do
        :sentinel -> Application.delete_env(:muse, :browser_access)
        _ -> Application.put_env(:muse, :browser_access, original_access_val)
      end

      case original_enforced_val do
        :sentinel -> Application.delete_env(:muse, :browser_access_enforced)
        _ -> Application.put_env(:muse, :browser_access_enforced, original_enforced_val)
      end

      if original_sys do
        System.put_env("MUSE_BROWSER_ACCESS", original_sys)
      else
        System.delete_env("MUSE_BROWSER_ACCESS")
      end
    end)

    :ok
  end

  # -- enforce_local_only/1 (direct) -------------------------------------------

  describe "enforce_local_only/1" do
    test "allows loopback IPv4 127.0.0.1" do
      conn = conn(:get, "/") |> Map.put(:remote_ip, {127, 0, 0, 1})
      result = BrowserAccessControl.enforce_local_only(conn)
      refute result.halted
    end

    test "allows any 127.x.x.x" do
      conn = conn(:get, "/") |> Map.put(:remote_ip, {127, 255, 0, 1})
      result = BrowserAccessControl.enforce_local_only(conn)
      refute result.halted
    end

    test "allows IPv6 loopback ::1" do
      conn = conn(:get, "/") |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0, 0, 1})
      result = BrowserAccessControl.enforce_local_only(conn)
      refute result.halted
    end

    test "allows IPv4-mapped IPv6 loopback" do
      conn =
        conn(:get, "/")
        |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})

      result = BrowserAccessControl.enforce_local_only(conn)
      refute result.halted
    end

    test "rejects non-loopback IPv4 with 403" do
      conn = conn(:get, "/") |> Map.put(:remote_ip, {192, 168, 1, 100})
      result = BrowserAccessControl.enforce_local_only(conn)
      assert result.halted
      assert result.status == 403
    end

    test "rejects non-loopback IPv6 with 403" do
      conn =
        conn(:get, "/")
        |> Map.put(:remote_ip, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})

      result = BrowserAccessControl.enforce_local_only(conn)
      assert result.halted
      assert result.status == 403
    end

    test "rejects 0.0.0.0 (wildcard) with 403" do
      conn = conn(:get, "/") |> Map.put(:remote_ip, {0, 0, 0, 0})
      result = BrowserAccessControl.enforce_local_only(conn)
      assert result.halted
      assert result.status == 403
    end

    test "error body is plain text and non-leaking" do
      conn = conn(:get, "/") |> Map.put(:remote_ip, {10, 0, 0, 1})
      result = BrowserAccessControl.enforce_local_only(conn)

      body = result.resp_body
      assert body =~ "403 Forbidden"
      assert body =~ "local access"
      # Must NOT contain internal IPs, config values, secrets
      refute body =~ "10.0.0.1"
      refute body =~ "192.168"
      refute body =~ "secret"
      refute body =~ "token"
    end

    test "error content type is text/plain" do
      conn = conn(:get, "/") |> Map.put(:remote_ip, {10, 0, 0, 1})
      result = BrowserAccessControl.enforce_local_only(conn)

      assert {:ok, "text", "plain", %{}} =
               Plug.Conn.get_resp_header(result, "content-type")
               |> List.first("")
               |> Plug.Conn.Utils.content_type()
    end

    test "loopback requests are not halted and have no 403 status" do
      conn = conn(:get, "/") |> Map.put(:remote_ip, {127, 0, 0, 1})
      result = BrowserAccessControl.enforce_local_only(conn)
      refute result.halted
      # Status is nil for un-halted connections (not yet sent)
      refute result.status == 403
    end
  end

  # -- call/2 (plug integration) -----------------------------------------------

  describe "call/2 — plug integration" do
    test "bypasses when browser_access_enforced is false" do
      Application.put_env(:muse, :browser_access_enforced, false)
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")

      # Non-loopback IP — would be rejected if enforced
      conn = conn(:get, "/") |> Map.put(:remote_ip, {192, 168, 1, 1})
      result = BrowserAccessControl.call(conn, [])
      refute result.halted
    end

    test "enforces local_only when browser_access_enforced is true and mode is local_only" do
      Application.put_env(:muse, :browser_access_enforced, true)
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")

      # Loopback — allowed
      conn_loopback = conn(:get, "/") |> Map.put(:remote_ip, {127, 0, 0, 1})
      result_loopback = BrowserAccessControl.call(conn_loopback, [])
      refute result_loopback.halted

      # Non-loopback — rejected
      conn_remote = conn(:get, "/") |> Map.put(:remote_ip, {192, 168, 1, 1})
      result_remote = BrowserAccessControl.call(conn_remote, [])
      assert result_remote.halted
      assert result_remote.status == 403
    end

    test "allows all IPs when mode is :open and enforced" do
      Application.put_env(:muse, :browser_access_enforced, true)
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")

      conn = conn(:get, "/") |> Map.put(:remote_ip, {8, 8, 8, 8})
      result = BrowserAccessControl.call(conn, [])
      refute result.halted
    end

    test "falls through to local_only for :authenticated mode (not yet implemented)" do
      Application.put_env(:muse, :browser_access_enforced, true)
      Application.put_env(:muse, :browser_access, mode: :authenticated)
      System.delete_env("MUSE_BROWSER_ACCESS")

      # Loopback should still work
      conn_loopback = conn(:get, "/") |> Map.put(:remote_ip, {127, 0, 0, 1})
      result_loopback = BrowserAccessControl.call(conn_loopback, [])
      refute result_loopback.halted

      # Non-loopback should be rejected (falls back to local_only)
      conn_remote = conn(:get, "/") |> Map.put(:remote_ip, {10, 0, 0, 1})
      result_remote = BrowserAccessControl.call(conn_remote, [])
      assert result_remote.halted
      assert result_remote.status == 403
    end

    test "env var MUSE_BROWSER_ACCESS=open overrides app config" do
      Application.put_env(:muse, :browser_access_enforced, true)
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.put_env("MUSE_BROWSER_ACCESS", "open")

      conn = conn(:get, "/") |> Map.put(:remote_ip, {8, 8, 8, 8})
      result = BrowserAccessControl.call(conn, [])
      refute result.halted
    end
  end

  # -- init/1 -------------------------------------------------------------------

  describe "init/1" do
    test "returns opts unchanged" do
      assert BrowserAccessControl.init([]) == []
      assert BrowserAccessControl.init(some: :option) == [some: :option]
    end
  end
end
