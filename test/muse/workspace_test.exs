defmodule Muse.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Muse.Workspace

  # Globally named Agent — must stop any leftover process before each test.

  setup do
    stop_workspace()
    root = Path.join(System.tmp_dir!(), "muse_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> stop_workspace() end)
    {:ok, root: root}
  end

  # -- root/0 -------------------------------------------------------------------

  describe "root/0" do
    test "returns an absolute path", %{root: root} do
      {:ok, _} = Workspace.start_link(root: root)
      assert Path.type(Workspace.root()) == :absolute
    end

    test "is expanded from the provided :root option", %{root: root} do
      {:ok, _} = Workspace.start_link(root: root)
      assert Workspace.root() == Path.expand(root)
    end
  end

  # -- resolve!/1 — happy paths -------------------------------------------------

  describe "resolve!/1 — relative paths" do
    test "resolves a relative path inside root", %{root: root} do
      {:ok, _} = Workspace.start_link(root: root)
      assert Workspace.resolve!("lib/foo.ex") == Path.join(root, "lib/foo.ex")
    end

    test "resolves a nested relative path inside root", %{root: root} do
      {:ok, _} = Workspace.start_link(root: root)
      assert Workspace.resolve!("src/deep/file.ex") == Path.join(root, "src/deep/file.ex")
    end
  end

  describe "resolve!/1 — absolute paths" do
    test "accepts an absolute path inside root", %{root: root} do
      {:ok, _} = Workspace.start_link(root: root)
      abs = Path.join(root, "lib/foo.ex")
      assert Workspace.resolve!(abs) == abs
    end

    test "accepts the workspace root itself", %{root: root} do
      {:ok, _} = Workspace.start_link(root: root)
      assert Workspace.resolve!(root) == root
    end
  end

  # -- resolve!/1 — escape rejections ------------------------------------------

  describe "resolve!/1 — path escapes" do
    test "../outside raises ArgumentError", %{root: root} do
      {:ok, _} = Workspace.start_link(root: root)

      assert_raise ArgumentError, ~r/escapes workspace/, fn ->
        Workspace.resolve!("../outside")
      end
    end

    test "sibling prefix escape is rejected", %{root: root} do
      # root is something like /tmp/muse_ws_12345; create /tmp/muse_ws_12345bar
      sibling = root <> "bar"
      File.mkdir_p!(sibling)
      {:ok, _} = Workspace.start_link(root: root)
      escape_path = Path.join(sibling, "file")

      assert_raise ArgumentError, ~r/escapes workspace/, fn ->
        Workspace.resolve!(escape_path)
      end
    end

    test "absolute path outside root is rejected", %{root: root} do
      {:ok, _} = Workspace.start_link(root: root)

      assert_raise ArgumentError, ~r/escapes workspace/, fn ->
        Workspace.resolve!("/etc/passwd")
      end
    end
  end

  # -- Helpers ------------------------------------------------------------------

  defp stop_workspace do
    case Process.whereis(Workspace) do
      nil -> :ok
      pid -> GenServer.stop(pid, :shutdown)
    end
  end
end
