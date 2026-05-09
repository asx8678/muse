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
      large_content = String.duplicate("line of text\n", 50_000)
      File.write!(Path.join(root, "huge.ex"), large_content)

      result = ReadFile.execute(%{"path" => "huge.ex"}, %{workspace: root})
      assert result.success
      assert result.output.truncated == true
      assert byte_size(result.output.content) <= 500_000 + 10_000
    end

    test "uses bounded IO — never reads full file into memory", %{root: root} do
      large_content = String.duplicate("x", 1_000_000)
      File.write!(Path.join(root, "giant.ex"), large_content)

      result = ReadFile.execute(%{"path" => "giant.ex"}, %{workspace: root})
      assert result.success
      assert result.output.truncated == true
      assert byte_size(result.output.content) <= 600_000
    end

    test "binary file detection works on first 8KB", %{root: root} do
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

  describe "execute/2 — UTF-8 and binary safety (muse-qw4.13)" do
    test "rejects invalid UTF-8 file without crashing", %{root: root} do
      File.write!(Path.join(root, "invalid_utf8.txt"), <<0xFF, 0xFE, 0xFD>>)
      result = ReadFile.execute(%{"path" => "invalid_utf8.txt"}, %{workspace: root})
      refute result.success
      assert result.error =~ "invalid UTF-8"
    end

    test "rejects file with NUL bytes", %{root: root} do
      File.write!(Path.join(root, "nul_file.txt"), "hello" <> <<0>> <> "world")
      result = ReadFile.execute(%{"path" => "nul_file.txt"}, %{workspace: root})
      refute result.success
      assert result.error =~ "binary"
    end

    test "rejects file with excessive control characters", %{root: root} do
      control_bytes = for _ <- 1..200, into: <<>>, do: <<0x01>>
      text = String.duplicate("a", 3000)
      File.write!(Path.join(root, "ctrl_chars.bin"), control_bytes <> text)
      result = ReadFile.execute(%{"path" => "ctrl_chars.bin"}, %{workspace: root})
      refute result.success
      assert result.error =~ "control characters" or result.error =~ "binary"
    end

    test "valid UTF-8 with multibyte characters works as before", %{root: root} do
      content = "café 🌍 日本語\nline2\n"
      File.write!(Path.join(root, "utf8.txt"), content)
      result = ReadFile.execute(%{"path" => "utf8.txt"}, %{workspace: root})
      assert result.success
      assert result.output.content =~ "café"
      assert result.output.content =~ "日本語"
    end

    test "truncation respects multibyte UTF-8 boundaries", %{root: root} do
      # Each "café\n" = 6 bytes, so 84_000 lines = ~504KB > @max_bytes (500_000)
      large_content = String.duplicate("café\n", 84_000)
      File.write!(Path.join(root, "utf8_large.txt"), large_content)
      result = ReadFile.execute(%{"path" => "utf8_large.txt"}, %{workspace: root})
      assert result.success
      assert result.output.truncated == true
      # The output must be valid UTF-8 (no split multibyte chars)
      assert String.valid?(result.output.content)
    end

    test "large binary-ish content (no NUL, but invalid UTF-8) returns safe error", %{root: root} do
      # Invalid UTF-8 sequences without NUL bytes
      chunk = <<0xC3>> <> String.duplicate("a", 99) <> <<0xFF>>
      large_binary = String.duplicate(chunk, 100)
      File.write!(Path.join(root, "bad_utf8_large.bin"), large_binary)
      result = ReadFile.execute(%{"path" => "bad_utf8_large.bin"}, %{workspace: root})
      refute result.success
      assert result.error =~ "invalid UTF-8"
    end

    test "rejects invalid UTF-8 after the first 8KB sample without crashing", %{root: root} do
      File.write!(
        Path.join(root, "late_invalid_utf8.txt"),
        String.duplicate("a", 9000) <> <<0xFF>>
      )

      result = ReadFile.execute(%{"path" => "late_invalid_utf8.txt"}, %{workspace: root})
      refute result.success
      assert result.error =~ "invalid UTF-8"
    end

    test "rejects NUL bytes after the first 8KB sample", %{root: root} do
      File.write!(Path.join(root, "late_nul.txt"), String.duplicate("a", 9000) <> <<0>> <> "tail")
      result = ReadFile.execute(%{"path" => "late_nul.txt"}, %{workspace: root})
      refute result.success
      assert result.error =~ "binary"
    end
  end

  describe "execute/2 — start_line past EOF" do
    test "returns empty content cleanly when start_line exceeds file length", %{root: root} do
      result = ReadFile.execute(%{"path" => "hello.ex", "start_line" => 100}, %{workspace: root})
      assert result.success
      assert result.output.content == ""
      assert result.output.lines == 0
      assert result.output.start_line == 100
    end

    test "start_line at exact EOF returns empty content", %{root: root} do
      result = ReadFile.execute(%{"path" => "hello.ex", "start_line" => 7}, %{workspace: root})
      assert result.success
      assert result.output.content == ""
      assert result.output.lines == 0
    end
  end
end
