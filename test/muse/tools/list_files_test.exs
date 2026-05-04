defmodule Muse.Tools.ListFilesTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.ListFiles

  @symlinks_supported? (fn ->
                          base =
                            Path.join(
                              System.tmp_dir!(),
                              "muse_lf_symlink_probe_#{System.unique_integer([:positive])}"
                            )

                          target = Path.join(base, "target")
                          link = Path.join(base, "link")

                          try do
                            File.mkdir_p!(base)
                            File.write!(target, "ok")
                            File.ln_s(target, link) == :ok
                          rescue
                            _ -> false
                          catch
                            _, _ -> false
                          after
                            File.rm_rf(base)
                          end
                        end).()

  setup do
    root = Path.join(System.tmp_dir!(), "muse_lf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "lib/app.ex"), "defmodule App do end")
    File.write!(Path.join(root, "lib/util.ex"), "defmodule Util do end")
    File.write!(Path.join(root, "README.md"), "# Test")
    # Create hidden/secret/ignored entries
    File.write!(Path.join(root, ".env"), "SECRET=123")
    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join(root, "_build/compiled.ex"), "compiled")
    File.mkdir_p!(Path.join(root, "deps"))
    File.write!(Path.join(root, "deps/phoenix.ex"), "dep")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  describe "execute/2" do
    test "lists files in workspace root", %{root: root} do
      result = ListFiles.execute(%{}, %{workspace: root})
      assert result.success
      assert is_list(result.output.entries)
      # Should include lib/ and test/ and README.md
      assert Enum.any?(result.output.entries, &String.starts_with?(&1, "lib/"))
      assert "README.md" in result.output.entries
    end

    test "omits secret files", %{root: root} do
      result = ListFiles.execute(%{}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.entries, &String.contains?(&1, ".env"))
    end

    test "omits ignored directories", %{root: root} do
      result = ListFiles.execute(%{}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.entries, &String.starts_with?(&1, "_build/"))
      refute Enum.any?(result.output.entries, &String.starts_with?(&1, "deps/"))
    end

    test "omits hidden files by default", %{root: root} do
      result = ListFiles.execute(%{}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.entries, &String.starts_with?(&1, "."))
    end

    test "includes hidden files when allow_hidden is true", %{root: root} do
      result = ListFiles.execute(%{"allow_hidden" => true}, %{workspace: root})
      assert result.success
      # .env is secret so it should still be excluded even with allow_hidden
      # but .formatter.exs etc would be included if they existed
    end

    test "respects max_entries", %{root: root} do
      result = ListFiles.execute(%{"max_entries" => 1}, %{workspace: root})
      assert result.success
      assert length(result.output.entries) <= 1
      assert result.output.truncated == true
    end

    test "lists entries in subdirectory", %{root: root} do
      result = ListFiles.execute(%{"path" => "lib"}, %{workspace: root})
      assert result.success
      assert Enum.all?(result.output.entries, &String.starts_with?(&1, "lib/"))
    end

    test "returns root in output", %{root: root} do
      result = ListFiles.execute(%{}, %{workspace: root})
      assert result.output.root == root
    end

    test "returns error for path escaping workspace", %{root: root} do
      result = ListFiles.execute(%{"path" => "../../etc"}, %{workspace: root})
      refute result.success
    end

    test "returns error for non-directory path", %{root: root} do
      result = ListFiles.execute(%{"path" => "README.md"}, %{workspace: root})
      refute result.success
    end

    test "entries are sorted", %{root: root} do
      result = ListFiles.execute(%{}, %{workspace: root})
      assert result.success
      assert result.output.entries == Enum.sort(result.output.entries)
    end
  end

  describe "execute/2 — PR06 safety invariants" do
    test "never exposes .git contents even with allow_hidden", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/HEAD"), "ref: refs/heads/main")

      result = ListFiles.execute(%{"allow_hidden" => true}, %{workspace: root})
      assert result.success
      # .git entries should never appear — list_files doesn't use allow_git_contents
      refute Enum.any?(result.output.entries, &String.starts_with?(&1, ".git/"))
    end

    test "never exposes _build/deps even with allow_hidden", %{root: root} do
      result = ListFiles.execute(%{"allow_hidden" => true}, %{workspace: root})
      assert result.success
      refute Enum.any?(result.output.entries, &String.starts_with?(&1, "_build/"))
      refute Enum.any?(result.output.entries, &String.starts_with?(&1, "deps/"))
    end

    test "secret files excluded even with allow_hidden", %{root: root} do
      File.write!(Path.join(root, ".pypirc"), "[distutils]\nindex-servers = pypi")

      result = ListFiles.execute(%{"allow_hidden" => true}, %{workspace: root})
      assert result.success
      # Secret files like .pypirc must be excluded even with allow_hidden
      refute Enum.any?(result.output.entries, &String.contains?(&1, ".pypirc"))
    end

    if @symlinks_supported? do
      test "omits symlinks that resolve outside workspace", %{root: root} do
        outside =
          Path.join(System.tmp_dir!(), "muse_lf_outside_#{System.unique_integer([:positive])}")

        File.mkdir_p!(outside)
        File.write!(Path.join(outside, "secret.txt"), "leaked")

        try do
          # Create a symlink inside workspace that points outside
          link_path = Path.join(root, "outside_link")
          File.rm(link_path)
          :ok = File.ln_s(outside, link_path)

          result = ListFiles.execute(%{"allow_hidden" => true}, %{workspace: root})
          assert result.success
          # The symlink-to-outside must be omitted
          refute Enum.any?(result.output.entries, &String.contains?(&1, "outside_link"))
        after
          File.rm_rf(outside)
        end
      end
    else
      @tag skip: "symlink creation unavailable on this platform"
      test "omits symlinks that resolve outside workspace" do
        :ok
      end
    end
  end
end
