defmodule Muse.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.ReadFile

  setup do
    root = Path.join(System.tmp_dir!(), "muse_rf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.ex"), "line1\nline2\nline3\nline4\nline5\n")
    File.write!(Path.join(root, ".env"), "SECRET_KEY=abc123")
    File.write!(Path.join(root, "binary.bin"), <<0, 1, 2, 3, 0, 5, 6>>)

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  describe "execute/2" do
    test "reads a text file", %{root: root} do
      result = ReadFile.execute(%{"path" => "hello.ex"}, %{workspace: root})
      assert result.success
      assert result.output.content =~ "line1"
      assert result.output.path == "hello.ex"
    end

    test "returns line count", %{root: root} do
      result = ReadFile.execute(%{"path" => "hello.ex"}, %{workspace: root})
      assert result.success
      assert result.output.lines > 0
    end

    test "respects start_line", %{root: root} do
      result = ReadFile.execute(%{"path" => "hello.ex", "start_line" => 2}, %{workspace: root})
      assert result.success
      assert result.output.start_line == 2
      refute result.output.content =~ "line1"
      assert result.output.content =~ "line2"
    end

    test "respects end_line", %{root: root} do
      result =
        ReadFile.execute(%{"path" => "hello.ex", "start_line" => 1, "end_line" => 2}, %{
          workspace: root
        })

      assert result.success
      assert result.output.end_line == 2
    end

    test "returns error when path is missing" do
      result = ReadFile.execute(%{}, %{workspace: "/tmp"})
      refute result.success
      assert result.error =~ "path is required"
    end

    test "returns error for file not found", %{root: root} do
      result = ReadFile.execute(%{"path" => "nonexistent.ex"}, %{workspace: root})
      refute result.success
      assert result.error =~ "not found"
    end

    test "blocks binary files", %{root: root} do
      result = ReadFile.execute(%{"path" => "binary.bin"}, %{workspace: root})
      refute result.success
      assert result.error =~ "binary"
    end

    test "blocks secret paths", %{root: root} do
      result = ReadFile.execute(%{"path" => ".env"}, %{workspace: root})
      refute result.success
    end

    test "returns error for directory", %{root: root} do
      File.mkdir_p!(Path.join(root, "subdir"))
      result = ReadFile.execute(%{"path" => "subdir"}, %{workspace: root})
      refute result.success
      assert result.error =~ "directory"
    end

    test "blocks path escaping workspace", %{root: root} do
      result = ReadFile.execute(%{"path" => "../../etc/passwd"}, %{workspace: root})
      refute result.success
    end

    test "includes metadata", %{root: root} do
      result = ReadFile.execute(%{"path" => "hello.ex"}, %{workspace: root})
      assert result.success
      assert is_map(result.output.metadata)
      assert result.output.metadata.byte_size > 0
    end
  end

  describe "execute/2 — bounded IO and binary safety (PR06 Blocker 4)" do
    test "truncates files exceeding max_bytes", %{root: root} do
      # Create a file larger than @max_bytes (500_000)
      large_content = String.duplicate("line of text\n", 50_000)
      File.write!(Path.join(root, "huge.ex"), large_content)

      result = ReadFile.execute(%{"path" => "huge.ex"}, %{workspace: root})
      assert result.success
      assert result.output.truncated == true
      # Output should be bounded
      assert byte_size(result.output.content) <= 500_000 + 10_000
    end

    test "uses bounded IO — never reads full file into memory", %{root: root} do
      # Create a very large file to prove bounded read works
      large_content = String.duplicate("x", 1_000_000)
      File.write!(Path.join(root, "giant.ex"), large_content)

      result = ReadFile.execute(%{"path" => "giant.ex"}, %{workspace: root})
      assert result.success
      assert result.output.truncated == true
      # Content must be much smaller than the 1MB file
      assert byte_size(result.output.content) <= 600_000
    end

    test "binary file detection works on first 8KB", %{root: root} do
      # Binary file with null byte in first 8KB
      bin_content = <<0, 1, 2, 3>> <> String.duplicate("x", 16_000)
      File.write!(Path.join(root, "early_binary.bin"), bin_content)

      result = ReadFile.execute(%{"path" => "early_binary.bin"}, %{workspace: root})
      refute result.success
      assert result.error =~ "binary"
    end

    test "rejects secret path even with traversal", %{root: root} do
      File.mkdir_p!(Path.join(root, "config"))
      File.write!(Path.join(root, "config/.env.production"), "PROD_SECRET=xyz")

      result = ReadFile.execute(%{"path" => "config/.env.production"}, %{workspace: root})
      refute result.success
    end
  end

  describe "execute/2 — start_line past EOF" do
    test "returns empty content cleanly when start_line exceeds file length", %{root: root} do
      # hello.ex: "line1\nline2\n...\nline5\n" splits to 6 lines;
      # start_line=100 is well past EOF
      result = ReadFile.execute(%{"path" => "hello.ex", "start_line" => 100}, %{workspace: root})
      assert result.success
      assert result.output.content == ""
      assert result.output.lines == 0
      assert result.output.start_line == 100
    end

    test "start_line at exact EOF returns empty content", %{root: root} do
      # hello.ex has 6 lines after split (trailing newline creates empty line 6);
      # start_line=7 is just past the last line
      result = ReadFile.execute(%{"path" => "hello.ex", "start_line" => 7}, %{workspace: root})
      assert result.success
      assert result.output.content == ""
      assert result.output.lines == 0
    end
  end
end
