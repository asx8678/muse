defmodule Muse.WorkspaceSafetyTest do
  use ExUnit.Case, async: false

  alias Muse.Workspace

  setup do
    stop_workspace()
    root = Path.join(System.tmp_dir!(), "muse_ws_safety_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      stop_workspace()
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  # -- safe_resolve!/2 — workspace boundary --------------------------------------

  describe "safe_resolve!/2 — workspace boundary" do
    test "resolves relative path inside workspace", %{root: root} do
      assert Workspace.safe_resolve!("lib/muse.ex", root) == Path.join(root, "lib/muse.ex")
    end

    test "rejects ../ traversal outside workspace", %{root: root} do
      assert_raise ArgumentError, ~r/escapes workspace/, fn ->
        Workspace.safe_resolve!("../outside", root)
      end
    end

    test "rejects absolute path without allow_absolute", %{root: root} do
      abs_path = Path.join(root, "lib/muse.ex")

      assert_raise ArgumentError, ~r/absolute path.*not allowed/, fn ->
        Workspace.safe_resolve!(abs_path, root)
      end
    end

    test "accepts absolute path with allow_absolute: true", %{root: root} do
      abs_path = Path.join(root, "lib/muse.ex")
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(abs_path, "content")

      assert Workspace.safe_resolve!(abs_path, root, allow_absolute: true) == abs_path
    end

    test "rejects absolute path outside workspace even with allow_absolute", %{root: root} do
      assert_raise ArgumentError, ~r/escapes workspace/, fn ->
        Workspace.safe_resolve!("/etc/passwd", root, allow_absolute: true)
      end
    end
  end

  # -- safe_resolve!/2 — hidden files -------------------------------------------

  describe "safe_resolve!/2 — hidden files" do
    test "rejects hidden files by default", %{root: root} do
      assert_raise ArgumentError, ~r/hidden file/, fn ->
        Workspace.safe_resolve!(".hidden_file", root)
      end
    end

    test "rejects hidden directory components by default", %{root: root} do
      assert_raise ArgumentError, ~r/hidden file/, fn ->
        Workspace.safe_resolve!(".hidden/file.ex", root)
      end
    end

    test "allows hidden files with allow_hidden: true", %{root: root} do
      assert Workspace.safe_resolve!(".hidden_file", root, allow_hidden: true) ==
               Path.join(root, ".hidden_file")
    end
  end

  # -- safe_resolve!/2 — secret paths -------------------------------------------

  describe "safe_resolve!/2 — secret paths" do
    test "rejects .env file", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!(".env", root, allow_hidden: true)
      end
    end

    test "rejects .env.local", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!(".env.local", root, allow_hidden: true)
      end
    end

    test "rejects .pem files", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!("server.pem", root)
      end
    end

    test "rejects .key files", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!("private.key", root)
      end
    end

    test "rejects id_rsa", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!("id_rsa", root, allow_hidden: true)
      end
    end

    test "rejects id_ed25519", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!("id_ed25519", root, allow_hidden: true)
      end
    end

    test "rejects .ssh/ directory", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!(".ssh/config", root, allow_hidden: true)
      end
    end

    test "rejects .aws/ directory", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!(".aws/credentials", root, allow_hidden: true)
      end
    end

    test "rejects .npmrc", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!(".npmrc", root, allow_hidden: true)
      end
    end

    test "rejects .netrc", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!(".netrc", root, allow_hidden: true)
      end
    end

    test "rejects credentials.json", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!("credentials.json", root)
      end
    end

    test "rejects auth.json", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!("auth.json", root)
      end
    end

    test "rejects secrets.yml", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!("secrets.yml", root)
      end
    end

    test "rejects .p12 files", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!("cert.p12", root)
      end
    end

    test "rejects .pfx files", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!("cert.pfx", root)
      end
    end

    test "rejects .git-credentials", %{root: root} do
      assert_raise ArgumentError, ~r/secret/, fn ->
        Workspace.safe_resolve!(".git-credentials", root, allow_hidden: true)
      end
    end

    test "allows normal source files", %{root: root} do
      assert Workspace.safe_resolve!("lib/muse.ex", root) == Path.join(root, "lib/muse.ex")
    end
  end

  # -- safe_resolve!/2 — ignored paths -------------------------------------------

  describe "safe_resolve!/2 — ignored paths" do
    test "rejects _build/ paths", %{root: root} do
      assert_raise ArgumentError, ~r/ignored/, fn ->
        Workspace.safe_resolve!("_build/lib/muse.ex", root)
      end
    end

    test "rejects deps/ paths", %{root: root} do
      assert_raise ArgumentError, ~r/ignored/, fn ->
        Workspace.safe_resolve!("deps/phoenix/lib/phoenix.ex", root)
      end
    end

    test "rejects node_modules/ paths", %{root: root} do
      assert_raise ArgumentError, ~r/ignored/, fn ->
        Workspace.safe_resolve!("node_modules/react/index.js", root)
      end
    end

    test "rejects .git/ paths by default", %{root: root} do
      assert_raise ArgumentError, ~r/hidden file|ignored/, fn ->
        Workspace.safe_resolve!(".git/config", root)
      end
    end

    test "allows .git/ paths with allow_git_contents: true and allow_hidden: true", %{root: root} do
      assert Workspace.safe_resolve!(".git/config", root,
               allow_git_contents: true,
               allow_hidden: true
             ) == Path.join(root, ".git/config")
    end
  end

  # -- secret_path?/2 ------------------------------------------------------------

  describe "secret_path?/2" do
    test "detects .env", %{root: root} do
      assert Workspace.secret_path?(Path.join(root, ".env"), root)
    end

    test "detects nested .env.production", %{root: root} do
      assert Workspace.secret_path?(Path.join(root, "config/.env.production"), root)
    end

    test "detects .ssh directory", %{root: root} do
      assert Workspace.secret_path?(Path.join(root, ".ssh/id_rsa"), root)
    end

    test "allows normal files", %{root: root} do
      refute Workspace.secret_path?(Path.join(root, "lib/muse.ex"), root)
    end

    test "detects .pem anywhere in path", %{root: root} do
      assert Workspace.secret_path?(Path.join(root, "certs/server.pem"), root)
    end
  end

  # -- ignored_path?/2 -----------------------------------------------------------

  describe "ignored_path?/2" do
    test "detects _build paths", %{root: root} do
      assert Workspace.ignored_path?(Path.join(root, "_build/lib/mix.ex"), root, [])
    end

    test "detects deps paths", %{root: root} do
      assert Workspace.ignored_path?(Path.join(root, "deps/phoenix/mix.exs"), root, [])
    end

    test "detects .git paths by default", %{root: root} do
      assert Workspace.ignored_path?(Path.join(root, ".git/HEAD"), root, [])
    end

    test "allows .git with allow_git_contents: true", %{root: root} do
      refute Workspace.ignored_path?(Path.join(root, ".git/HEAD"), root, allow_git_contents: true)
    end

    test "allows normal paths", %{root: root} do
      refute Workspace.ignored_path?(Path.join(root, "lib/muse.ex"), root, [])
    end
  end

  # -- safe_resolve!/2 preserves resolve!/1 behavior ----------------------------

  describe "safe_resolve!/2 does not break resolve!/1 semantics" do
    test "resolves nested relative paths correctly", %{root: root} do
      expected = Path.join(root, "src/deep/file.ex")
      assert Workspace.safe_resolve!("src/deep/file.ex", root) == expected
    end

    test "rejects sibling prefix escapes", %{root: root} do
      sibling = root <> "bar"
      File.mkdir_p!(sibling)
      escape_path = Path.join(sibling, "file")

      assert_raise ArgumentError, ~r/escapes workspace/, fn ->
        Workspace.safe_resolve!(escape_path, root, allow_absolute: true)
      end
    end
  end

  # -- PR06 Blocker 5: secret_path? relative to workspace; safe_resolve! overloads --

  describe "PR06 — secret_path? is relative to workspace" do
    test "does not false-positive on parent dir named .env", %{root: root} do
      # If workspace is at /tmp/.env/project/, the parent ".env" should NOT
      # cause secret_path? to return true for files within the project
      env_root = Path.join(root, ".env")
      File.mkdir_p!(env_root)
      # A file at the workspace root itself is not secret (it's the root)
      refute Workspace.secret_path?(root, root)
    end

    test "detects secret within workspace, not in parent path", %{root: root} do
      # lib/.env should be detected because ".env" is a relative part
      assert Workspace.secret_path?(Path.join(root, "lib/.env"), root)
    end

    test "workspace root itself is never a secret", %{root: root} do
      refute Workspace.secret_path?(root, root)
    end
  end

  describe "PR06 — safe_resolve! overloads" do
    test "2-arg opts overload uses Workspace.root()", %{root: root} do
      {:ok, _} = Workspace.start_link(root: root)

      on_exit(fn -> stop_workspace() end)

      assert Workspace.safe_resolve!("lib/muse.ex", allow_hidden: false) ==
               Path.join(root, "lib/muse.ex")
    end

    test "2-arg workspace overload defaults opts to []", %{root: root} do
      assert Workspace.safe_resolve!("lib/muse.ex", root) == Path.join(root, "lib/muse.ex")
    end

    test "3-arg full overload", %{root: root} do
      assert Workspace.safe_resolve!("lib/muse.ex", root, allow_hidden: false) ==
               Path.join(root, "lib/muse.ex")
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp stop_workspace do
    case Process.whereis(Muse.Workspace) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
    end
  end
end
