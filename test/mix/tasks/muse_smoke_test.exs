defmodule Mix.Tasks.Muse.SmokeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Muse.Smoke

  describe "parse_args/1" do
    test "uses loopback host and non-default smoke port by default" do
      assert {:ok,
              %{
                host: "127.0.0.1",
                port: 4101,
                base_url: "http://127.0.0.1:4101"
              }} = Smoke.parse_args([])
    end

    test "accepts explicit host and port" do
      assert {:ok,
              %{
                host: "localhost",
                port: 4210,
                base_url: "http://localhost:4210"
              }} = Smoke.parse_args(["--host", "localhost", "--port", "4210"])
    end

    test "accepts short port alias" do
      assert {:ok, %{port: 4211, base_url: "http://127.0.0.1:4211"}} =
               Smoke.parse_args(["-p", "4211"])
    end

    test "rejects unknown flags" do
      assert {:error, message} = Smoke.parse_args(["--bogus"])
      assert message =~ "invalid or unknown smoke option(s): --bogus"
    end

    test "rejects positional arguments" do
      assert {:error, message} = Smoke.parse_args(["http://127.0.0.1:4101"])
      assert message =~ "unexpected positional argument(s): http://127.0.0.1:4101"
    end

    test "rejects non-integer port values" do
      assert {:error, message} = Smoke.parse_args(["--port", "abc"])
      assert message =~ "invalid or unknown smoke option(s): --port abc"
    end

    test "rejects port values below range" do
      assert {:error, message} = Smoke.parse_args(["--port", "0"])
      assert message =~ "invalid port 0; must be an integer in 1..65535"
    end

    test "rejects port values above range" do
      assert {:error, message} = Smoke.parse_args(["--port", "65536"])
      assert message =~ "invalid port 65536; must be an integer in 1..65535"
    end

    test "rejects host values that are full URLs" do
      assert {:error, message} = Smoke.parse_args(["--host", "http://127.0.0.1"])
      assert message =~ "invalid host"
      assert message =~ "not a URL"
    end

    test "rejects host values with an embedded port or path" do
      assert {:error, port_message} = Smoke.parse_args(["--host", "127.0.0.1:4101"])
      assert port_message =~ "without scheme, port, or path"

      assert {:error, path_message} = Smoke.parse_args(["--host", "localhost/smoke"])
      assert path_message =~ "not a URL"
    end

    test "rejects host values with whitespace" do
      assert {:error, message} = Smoke.parse_args(["--host", "local host"])
      assert message =~ "whitespace is not allowed"
    end
  end
end
