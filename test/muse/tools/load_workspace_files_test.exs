defmodule Muse.Tools.LoadWorkspaceFilesTest do
  use ExUnit.Case, async: false

  alias Muse.ActiveVFS
  alias Muse.Tools.LoadWorkspaceFiles

  # -- Helpers ------------------------------------------------------------------

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "lwf_test_#{:erlang.unique_integer([:positive])}")
  end

  defp stop_vfs do
    case Process.whereis(Muse.ActiveVFS) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp safe_stop(pid) do
    try do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp start_vfs(root) do
    stop_vfs()
    {:ok, _} = ActiveVFS.start_link(root: root)
    :ok
  end

  defp write_file(dir, rel_path, content) do
    abs = Path.join(dir, rel_path)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
  end

  setup do
    dir = tmp_dir()
    File.mkdir_p!(dir)

    on_exit(fn ->
      stop_vfs()
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  # -- Tests --------------------------------------------------------------------

  describe "execute/2" do
    test "returns error when files is missing" do
      result = LoadWorkspaceFiles.execute(%{}, %{})
      refute result.success
      assert result.error =~ "files is required"
    end

    test "returns error when files is not a list" do
      result = LoadWorkspaceFiles.execute(%{"files" => "not_a_list"}, %{})
      refute result.success
      assert result.error =~ "files must be a list"
    end

    test "returns error when files contains non-strings" do
      result = LoadWorkspaceFiles.execute(%{"files" => [123]}, %{})
      refute result.success
      assert result.error =~ "files must be a list"
    end

    test "loads files into VFS and returns content metadata", %{dir: dir} do
      write_file(dir, "lib/foo.ex", "line1\nline2\nline3")
      write_file(dir, "lib/bar.ex", "single line")

      start_vfs(dir)

      result = LoadWorkspaceFiles.execute(%{"files" => ["lib/foo.ex", "lib/bar.ex"]}, %{})
      assert result.success
      assert result.output.loaded_count == 2

      foo = Enum.find(result.output.files, &(&1.path == "lib/foo.ex"))
      assert foo.status == :loaded
      assert foo.lines == 3

      bar = Enum.find(result.output.files, &(&1.path == "lib/bar.ex"))
      assert bar.status == :loaded
      assert bar.lines == 1

      assert result.output.errors == []
    end

    test "reports not_found for missing files", %{dir: dir} do
      write_file(dir, "lib/exists.ex", "content\n")

      start_vfs(dir)

      result =
        LoadWorkspaceFiles.execute(%{"files" => ["lib/exists.ex", "lib/missing.ex"]}, %{})

      assert result.success
      assert result.output.loaded_count == 1

      exists = Enum.find(result.output.files, &(&1.path == "lib/exists.ex"))
      assert exists.status == :loaded

      missing = Enum.find(result.output.files, &(&1.path == "lib/missing.ex"))
      assert missing.status == :not_found
      assert missing.lines == 0

      assert "lib/missing.ex: not_found" in result.output.errors
    end

    test "loading same file twice is idempotent", %{dir: dir} do
      write_file(dir, "lib/idem.ex", "line1\nline2\n")

      start_vfs(dir)

      result =
        LoadWorkspaceFiles.execute(%{"files" => ["lib/idem.ex", "lib/idem.ex"]}, %{})

      assert result.success
      # Both loads succeed (VFS already has it in memory the second time)
      assert result.output.loaded_count == 2
    end

    test "returns error when VFS is not available", %{dir: _dir} do
      stop_vfs()

      result = LoadWorkspaceFiles.execute(%{"files" => ["lib/foo.ex"]}, %{})
      refute result.success
      assert result.error =~ "VFS not available"
    end

    test "accepts optional purpose argument without error", %{dir: dir} do
      write_file(dir, "lib/purpose.ex", "hello\n")
      start_vfs(dir)

      result =
        LoadWorkspaceFiles.execute(
          %{"files" => ["lib/purpose.ex"], "purpose" => "editing auth module"},
          %{}
        )

      assert result.success
      assert result.output.loaded_count == 1
    end

    test "handles empty files list gracefully" do
      # Need VFS started for the "available" path
      start_vfs(System.tmp_dir!())

      result = LoadWorkspaceFiles.execute(%{"files" => []}, %{})
      assert result.success
      assert result.output.loaded_count == 0
      assert result.output.files == []
      assert result.output.errors == []
    end
  end
end
