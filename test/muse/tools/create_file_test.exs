defmodule Muse.Tools.CreateFileTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.CreateFile

  setup do
    root = Path.join(System.tmp_dir!(), "muse_cf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  describe "execute/2" do
    test "returns error when path is missing", %{root: root} do
      result = CreateFile.execute(%{"content" => "hello"}, %{workspace: root})
      refute result.success
      assert result.error =~ "path is required"
    end

    test "returns error when content is missing", %{root: root} do
      result = CreateFile.execute(%{"path" => "test.txt"}, %{workspace: root})
      refute result.success
      assert result.error =~ "content is required"
    end

    test "successful file creation returns ok with path and byte_size", %{root: root} do
      result = CreateFile.execute(%{"path" => "test.txt", "content" => "hello world"}, %{workspace: root})
      assert result.success
      assert result.output.path == "test.txt"
      assert result.output.byte_size == 11
      assert result.output.metadata.created == true

      # Verify file was actually written
      assert File.read!(Path.join(root, "test.txt")) == "hello world"
    end

    test "creates parent directories automatically", %{root: root} do
      result =
        CreateFile.execute(
          %{"path" => "deep/nested/dir/file.txt", "content" => "nested content"},
          %{workspace: root}
        )

      assert result.success
      assert result.output.path == "deep/nested/dir/file.txt"
      assert File.read!(Path.join(root, "deep/nested/dir/file.txt")) == "nested content"
    end

    test "rejects binary content", %{root: root} do
      result =
        CreateFile.execute(
          %{"path" => "binary.bin", "content" => <<0, 1, 2, 3>>},
          %{workspace: root}
        )

      refute result.success
      assert result.error =~ "binary"
    end

    test "rejects content exceeding 500KB", %{root: root} do
      huge_content = String.duplicate("x", 500_001)

      result =
        CreateFile.execute(
          %{"path" => "huge.txt", "content" => huge_content},
          %{workspace: root}
        )

      refute result.success
      assert result.error =~ "exceeds maximum size"
    end
  end
end
