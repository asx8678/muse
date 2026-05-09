defmodule MuseWeb.BrowserAccessConfigTest do
  use ExUnit.Case, async: false

  alias MuseWeb.BrowserAccessConfig

  setup do
    original_access = Application.get_env(:muse, :browser_access)
    original_enforced = Application.get_env(:muse, :browser_access_enforced)
    original_endpoint = Application.get_env(:muse, MuseWeb.Endpoint)
    original_sys = System.get_env("MUSE_BROWSER_ACCESS")
    original_unsafe = System.get_env("MUSE_BROWSER_UNSAFE_BIND")

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

      if original_endpoint do
        Application.put_env(:muse, MuseWeb.Endpoint, original_endpoint)
      else
        Application.delete_env(:muse, MuseWeb.Endpoint)
      end

      if original_sys,
        do: System.put_env("MUSE_BROWSER_ACCESS", original_sys),
        else: System.delete_env("MUSE_BROWSER_ACCESS")

      if original_unsafe,
        do: System.put_env("MUSE_BROWSER_UNSAFE_BIND", original_unsafe),
        else: System.delete_env("MUSE_BROWSER_UNSAFE_BIND")
    end)

    :ok
  end

  # -- mode/0 -------------------------------------------------------------------

  describe "mode/0" do
    test "defaults to :local_only when no app env or env var is set" do
      Application.delete_env(:muse, :browser_access)
      System.delete_env("MUSE_BROWSER_ACCESS")
      assert BrowserAccessConfig.mode() == :local_only
    end

    test "returns :local_only from app config" do
      System.delete_env("MUSE_BROWSER_ACCESS")
      Application.put_env(:muse, :browser_access, mode: :local_only)
      assert BrowserAccessConfig.mode() == :local_only
    end

    test "returns :open from app config" do
      System.delete_env("MUSE_BROWSER_ACCESS")
      Application.put_env(:muse, :browser_access, mode: :open)
      assert BrowserAccessConfig.mode() == :open
    end

    test "returns :authenticated from app config" do
      System.delete_env("MUSE_BROWSER_ACCESS")
      Application.put_env(:muse, :browser_access, mode: :authenticated)
      assert BrowserAccessConfig.mode() == :authenticated
    end

    test "env var overrides app config" do
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.put_env("MUSE_BROWSER_ACCESS", "open")
      assert BrowserAccessConfig.mode() == :open
    end

    test "env var local_only works" do
      Application.delete_env(:muse, :browser_access)
      System.put_env("MUSE_BROWSER_ACCESS", "local_only")
      assert BrowserAccessConfig.mode() == :local_only
    end

    test "env var authenticated works" do
      Application.delete_env(:muse, :browser_access)
      System.put_env("MUSE_BROWSER_ACCESS", "authenticated")
      assert BrowserAccessConfig.mode() == :authenticated
    end

    test "invalid env var falls back to app config" do
      Application.put_env(:muse, :browser_access, mode: :open)
      System.put_env("MUSE_BROWSER_ACCESS", "INVALID")
      assert BrowserAccessConfig.mode() == :open
    end

    test "invalid env var with no app config falls back to default" do
      Application.delete_env(:muse, :browser_access)
      System.put_env("MUSE_BROWSER_ACCESS", "bad_value")
      assert BrowserAccessConfig.mode() == :local_only
    end

    test "invalid app config mode falls back to default" do
      System.delete_env("MUSE_BROWSER_ACCESS")
      Application.put_env(:muse, :browser_access, mode: :invalid)
      assert BrowserAccessConfig.mode() == :local_only
    end
  end

  # -- local_only?/0 and open?/0 -----------------------------------------------

  describe "local_only?/0" do
    test "returns true when mode is :local_only" do
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      assert BrowserAccessConfig.local_only?()
    end

    test "returns false when mode is :open" do
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      refute BrowserAccessConfig.local_only?()
    end
  end

  describe "open?/0" do
    test "returns true when mode is :open" do
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      assert BrowserAccessConfig.open?()
    end

    test "returns false when mode is :local_only" do
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      refute BrowserAccessConfig.open?()
    end
  end

  # -- loopback?/1 --------------------------------------------------------------

  describe "loopback?/1" do
    test "recognizes IPv4 loopback 127.0.0.1" do
      assert BrowserAccessConfig.loopback?({127, 0, 0, 1})
    end

    test "recognizes any 127.x.x.x as loopback" do
      assert BrowserAccessConfig.loopback?({127, 0, 0, 1})
      assert BrowserAccessConfig.loopback?({127, 255, 255, 254})
      assert BrowserAccessConfig.loopback?({127, 1, 2, 3})
    end

    test "recognizes IPv6 loopback ::1" do
      assert BrowserAccessConfig.loopback?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "recognizes IPv4-mapped IPv6 loopback ::ffff:127.0.0.1" do
      assert BrowserAccessConfig.loopback?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
    end

    test "rejects non-loopback IPv4" do
      refute BrowserAccessConfig.loopback?({192, 168, 1, 1})
      refute BrowserAccessConfig.loopback?({10, 0, 0, 1})
      refute BrowserAccessConfig.loopback?({172, 16, 0, 1})
      refute BrowserAccessConfig.loopback?({8, 8, 8, 8})
    end

    test "rejects 0.0.0.0 (wildcard)" do
      refute BrowserAccessConfig.loopback?({0, 0, 0, 0})
    end

    test "rejects non-loopback IPv6" do
      refute BrowserAccessConfig.loopback?({0, 0, 0, 0, 0, 0, 0, 0})
      refute BrowserAccessConfig.loopback?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end

    test "rejects link-local 169.254.x.x" do
      refute BrowserAccessConfig.loopback?({169, 254, 1, 1})
    end
  end

  # -- endpoint_ip/0 -----------------------------------------------------------

  describe "endpoint_ip/0" do
    test "returns configured IP from endpoint config" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4000])
      assert BrowserAccessConfig.endpoint_ip() == {127, 0, 0, 1}
    end

    test "returns {127,0,0,1} when no endpoint config" do
      Application.delete_env(:muse, MuseWeb.Endpoint)
      assert BrowserAccessConfig.endpoint_ip() == {127, 0, 0, 1}
    end

    test "returns {0,0,0,0} when configured as wildcard" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4000])
      assert BrowserAccessConfig.endpoint_ip() == {0, 0, 0, 0}
    end
  end

  # -- wildcard_ip?/1 ----------------------------------------------------------

  describe "wildcard_ip?/1" do
    test "recognizes 0.0.0.0 as wildcard" do
      assert BrowserAccessConfig.wildcard_ip?({0, 0, 0, 0})
    end

    test "recognizes :: as wildcard" do
      assert BrowserAccessConfig.wildcard_ip?({0, 0, 0, 0, 0, 0, 0, 0})
    end

    test "rejects non-wildcard addresses" do
      refute BrowserAccessConfig.wildcard_ip?({127, 0, 0, 1})
      refute BrowserAccessConfig.wildcard_ip?({192, 168, 1, 1})
      refute BrowserAccessConfig.wildcard_ip?({0, 0, 0, 0, 0, 0, 0, 1})
    end
  end

  # -- non_loopback_ip?/1 -------------------------------------------------------

  describe "non_loopback_ip?/1" do
    test "0.0.0.0 is non-loopback" do
      assert BrowserAccessConfig.non_loopback_ip?({0, 0, 0, 0})
    end

    test "192.168.x.x is non-loopback" do
      assert BrowserAccessConfig.non_loopback_ip?({192, 168, 1, 1})
    end

    test "127.0.0.1 is not non-loopback" do
      refute BrowserAccessConfig.non_loopback_ip?({127, 0, 0, 1})
    end

    test "link-local 169.254.x.x is non-loopback (reachable by other link machines)" do
      assert BrowserAccessConfig.non_loopback_ip?({169, 254, 1, 1})
    end
  end

  # -- assert_safe!/0 -----------------------------------------------------------

  describe "assert_safe!/0" do
    test "passes when loopback + local_only" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert BrowserAccessConfig.assert_safe!() == :ok
    end

    test "passes when loopback + open" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert BrowserAccessConfig.assert_safe!() == :ok
    end

    test "raises when 0.0.0.0 + local_only" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe!()
      end
    end

    test "raises when 0.0.0.0 + open" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe!()
      end
    end

    test "raises when 192.168.x.x + open (non-wildcard non-loopback)" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {192, 168, 1, 10}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe!()
      end
    end

    test "raises when 10.x.x.x + open (private network, non-loopback)" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {10, 0, 0, 1}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe!()
      end
    end

    test "raises when 169.254.x.x + local_only (link-local is non-loopback)" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {169, 254, 1, 1}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe!()
      end
    end

    test "raises when 192.168.x.x + local_only" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {192, 168, 1, 1}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe!()
      end
    end

    test "does not raise when 0.0.0.0 + MUSE_BROWSER_UNSAFE_BIND=1" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.put_env("MUSE_BROWSER_UNSAFE_BIND", "1")

      assert BrowserAccessConfig.assert_safe!() == :ok
    end

    test "env var MUSE_BROWSER_ACCESS=open triggers unsafe with 0.0.0.0" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.put_env("MUSE_BROWSER_ACCESS", "open")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe!()
      end
    end

    test "passes when link-local 169.254.x.x + MUSE_BROWSER_UNSAFE_BIND=1" do
      Application.put_env(:muse, MuseWeb.Endpoint, http: [ip: {169, 254, 1, 1}, port: 4000])
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.put_env("MUSE_BROWSER_UNSAFE_BIND", "1")

      assert BrowserAccessConfig.assert_safe!() == :ok
    end
  end

  # -- assert_safe_for_ip!/1 ---------------------------------------------------

  describe "assert_safe_for_ip!/1" do
    test "passes when loopback + local_only" do
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert BrowserAccessConfig.assert_safe_for_ip!({127, 0, 0, 1}) == :ok
    end

    test "raises when 0.0.0.0 + local_only" do
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe_for_ip!({0, 0, 0, 0})
      end
    end

    test "raises when 192.168.1.10 + open" do
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe_for_ip!({192, 168, 1, 10})
      end
    end

    test "passes with MUSE_BROWSER_UNSAFE_BIND=1 for any IP" do
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.put_env("MUSE_BROWSER_UNSAFE_BIND", "1")

      assert BrowserAccessConfig.assert_safe_for_ip!({0, 0, 0, 0}) == :ok
    end
  end

  # -- CLI --host override regression ------------------------------------------

  describe "CLI --host override safety" do
    test "--host 0.0.0.0 + local_only is caught by assert_safe_for_ip!" do
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      # Simulates what Application.start does: parse_host("0.0.0.0")
      effective_ip = Muse.Application.parse_host("0.0.0.0")
      assert effective_ip == {0, 0, 0, 0}

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe_for_ip!(effective_ip)
      end
    end

    test "--host 0.0.0.0 + open is caught by assert_safe_for_ip!" do
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      effective_ip = Muse.Application.parse_host("0.0.0.0")

      assert_raise RuntimeError, ~r/Unsafe browser access configuration/, fn ->
        BrowserAccessConfig.assert_safe_for_ip!(effective_ip)
      end
    end

    test "--host 0.0.0.0 with MUSE_BROWSER_UNSAFE_BIND=1 passes" do
      Application.put_env(:muse, :browser_access, mode: :open)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.put_env("MUSE_BROWSER_UNSAFE_BIND", "1")

      effective_ip = Muse.Application.parse_host("0.0.0.0")

      assert BrowserAccessConfig.assert_safe_for_ip!(effective_ip) == :ok
    end

    test "--host 127.0.0.1 + local_only passes" do
      Application.put_env(:muse, :browser_access, mode: :local_only)
      System.delete_env("MUSE_BROWSER_ACCESS")
      System.delete_env("MUSE_BROWSER_UNSAFE_BIND")

      effective_ip = Muse.Application.parse_host("127.0.0.1")

      assert BrowserAccessConfig.assert_safe_for_ip!(effective_ip) == :ok
    end
  end

  # -- valid_modes/0 ------------------------------------------------------------

  describe "valid_modes/0" do
    test "returns list of valid mode atoms" do
      modes = BrowserAccessConfig.valid_modes()
      assert :local_only in modes
      assert :authenticated in modes
      assert :open in modes
    end
  end
end
