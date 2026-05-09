defmodule Muse.Tool.SafeTextTest do
  use ExUnit.Case, async: true

  alias Muse.Tool.SafeText

  # ---------------------------------------------------------------------------
  # classify/1
  # ---------------------------------------------------------------------------

  describe "classify/1" do
    test "empty binary is :text" do
      assert SafeText.classify(<<>>) == :text
    end

    test "valid ASCII text is :text" do
      assert SafeText.classify("hello world\nline 2\n") == :text
    end

    test "valid UTF-8 with multibyte characters is :text" do
      # Japanese, emoji, accented chars
      assert SafeText.classify("こんにちは世界 🌍 café résumé") == :text
    end

    test "valid UTF-8 with common control chars (tab, newline, CR) is :text" do
      assert SafeText.classify("line1\tcol2\r\nline3\n") == :text
    end

    test "NUL byte is :binary_file" do
      assert SafeText.classify(<<0, 1, 2, 3, 0, 5, 6>>) == :binary_file
    end

    test "NUL byte even in otherwise valid text is :binary_file" do
      content = "hello" <> <<0>> <> "world"
      assert SafeText.classify(content) == :binary_file
    end

    test "invalid UTF-8 sequence is :invalid_utf8" do
      # 0xFF is never a valid UTF-8 start byte
      assert SafeText.classify(<<0xFF, 0xFE, 0xFD>>) == :invalid_utf8
    end

    test "truncated multibyte UTF-8 sequence is :invalid_utf8" do
      # 0xC3 is a 2-byte lead, but we only have the lead byte (missing continuation)
      assert SafeText.classify(<<0xC3>>) == :invalid_utf8
    end

    test "invalid continuation byte without lead is :invalid_utf8" do
      # 0x80 is a continuation byte that appears without a valid lead
      assert SafeText.classify("text" <> <<0x80>> <> "more") == :invalid_utf8
    end

    test "excessive control characters is :unsafe_text" do
      # Pack >5% of bytes as control chars (0x01–0x08, 0x0E–0x1F)
      # 200 bytes of control chars + 3000 bytes of text = 200/3200 ≈ 6.25%
      control_bytes = for _ <- 1..200, into: <<>>, do: <<0x01>>
      text = String.duplicate("a", 3000)
      assert SafeText.classify(control_bytes <> text) == :unsafe_text
    end

    test "sparse control characters is still :text" do
      # A few control chars in a large text body should be fine
      # 5 control chars + 1000 text = 5/1005 ≈ 0.5% (well under 5%)
      control_bytes = <<0x01, 0x02, 0x03, 0x04, 0x05>>
      text = String.duplicate("hello world\n", 100)
      assert SafeText.classify(control_bytes <> text) == :text
    end

    test "DEL (0x7F) counts as control character" do
      # Pack enough DELs to trigger unsafe_text
      dels = for _ <- 1..200, into: <<>>, do: <<0x7F>>
      text = String.duplicate("a", 3000)
      assert SafeText.classify(dels <> text) == :unsafe_text
    end

    test "control density only checks first 8KB of data" do
      # Control chars in bytes after 8KB should not affect classification
      text_8kb = String.duplicate("a", 8192)
      control_tail = for _ <- 1..500, into: <<>>, do: <<0x01>>
      # The control chars are beyond the 8KB sample window
      assert SafeText.classify(text_8kb <> control_tail) == :text
    end

    test "NUL bytes detected in full bounded data" do
      # NUL byte after the first 8KB sample still makes the data binary.
      content = String.duplicate("a", 9000) <> <<0>> <> String.duplicate("b", 1000)
      assert SafeText.classify(content) == :binary_file
    end

    test "invalid UTF-8 in full bounded data is :invalid_utf8" do
      content = String.duplicate("valid text ", 900) <> <<0xFF>> <> "more valid text"
      assert SafeText.classify(content) == :invalid_utf8
    end

    test "small sample (< 10 bytes) with sparse control chars stays :text" do
      # Very small samples shouldn't trigger density checks (minimum size guard)
      assert SafeText.classify("abc") == :text
      # 2-byte sample is too small for density check, so even all-control
      # bytes (without NUL) fall through to :text since String.valid? passes
      # for single-byte values 0x01–0x08 (they're valid Latin-1 codepoints)
      assert SafeText.classify(<<0x01, 0x02>>) == :text
    end
  end

  # ---------------------------------------------------------------------------
  # safe_truncate/2
  # ---------------------------------------------------------------------------

  describe "safe_truncate/2" do
    test "returns data unchanged when within limit" do
      assert SafeText.safe_truncate("hello", 10) == {:ok, "hello"}
    end

    test "truncates ASCII at exact boundary" do
      assert SafeText.safe_truncate("hello world", 5) == {:ok, "hello"}
    end

    test "truncation at exact byte length returns unchanged" do
      assert SafeText.safe_truncate("hello", 5) == {:ok, "hello"}
    end

    test "does not split multibyte UTF-8 character (2-byte)" do
      # "é" is 0xC3 0xA9 (2 bytes). Truncating at byte 5 in "café"
      # should produce "caf" (3 bytes), not "caf" + broken 0xC3
      assert SafeText.safe_truncate("café", 4) == {:ok, "caf"}
    end

    test "does not split multibyte UTF-8 character (3-byte)" do
      # "日" is 3 bytes (0xE6 0x97 0xA5). Truncating at byte 2 in "日本語"
      # should produce "" (empty), not a broken lead byte
      assert SafeText.safe_truncate("日本語", 2) == {:ok, ""}
    end

    test "does not split multibyte UTF-8 character (4-byte emoji)" do
      # "🌍" is 4 bytes (0xF0 0x9F 0x8D 0x81). Truncating at byte 3 in "🌍"
      # should produce "" (empty), not a broken lead byte
      assert SafeText.safe_truncate("🌍", 3) == {:ok, ""}
    end

    test "truncates after complete multibyte character" do
      # "café" = "caf" (3 bytes) + "é" (2 bytes) = 5 bytes
      # Truncating at byte 5 gives us "café" intact
      assert SafeText.safe_truncate("café", 5) == {:ok, "café"}
    end

    test "handles mixed multibyte content" do
      # "hello日本語" — "hello" = 5 bytes, "日" = 3 bytes, "本" = 3 bytes, "語" = 3 bytes
      # Total = 14 bytes. "hello日" = 8 bytes. Truncating at byte 8 gives "hello日"
      assert SafeText.safe_truncate("hello日本語", 8) == {:ok, "hello日"}
      # At byte 7, "日" (bytes 5-7) doesn't fit, so we get "hello"
      assert SafeText.safe_truncate("hello日本語", 7) == {:ok, "hello"}
    end

    test "zero max_bytes returns empty binary" do
      assert SafeText.safe_truncate("anything", 0) == {:ok, ""}
    end

    test "empty binary with any limit returns empty" do
      assert SafeText.safe_truncate("", 100) == {:ok, ""}
    end
  end

  # ---------------------------------------------------------------------------
  # safe_split_lines/1
  # ---------------------------------------------------------------------------

  describe "safe_split_lines/1" do
    test "splits valid UTF-8 text into lines" do
      assert SafeText.safe_split_lines("line1\nline2\nline3") ==
               {:ok, ["line1", "line2", "line3"]}
    end

    test "handles empty string" do
      assert SafeText.safe_split_lines("") == {:ok, [""]}
    end

    test "handles single line without newline" do
      assert SafeText.safe_split_lines("hello") == {:ok, ["hello"]}
    end

    test "returns error for NUL-containing binary" do
      assert SafeText.safe_split_lines(<<0, 1, 2>>) == {:error, "binary files are not supported"}
    end

    test "returns error for invalid UTF-8" do
      assert SafeText.safe_split_lines(<<0xFF, 0xFE>>) ==
               {:error, "file contains invalid UTF-8 and cannot be displayed as text"}
    end

    test "returns error for unsafe text (excessive control chars)" do
      control_bytes = for _ <- 1..200, into: <<>>, do: <<0x01>>
      text = String.duplicate("a", 3000)

      assert SafeText.safe_split_lines(control_bytes <> text) ==
               {:error, "file contains excessive control characters and may be binary"}
    end

    test "splits text with multibyte characters" do
      assert SafeText.safe_split_lines("café\n日本語") == {:ok, ["café", "日本語"]}
    end
  end

  # ---------------------------------------------------------------------------
  # safe_string_contains?/2
  # ---------------------------------------------------------------------------

  describe "safe_string_contains?/2" do
    test "finds pattern in valid text" do
      assert SafeText.safe_string_contains?("hello world", "world") == {:ok, true}
    end

    test "returns false when pattern not found" do
      assert SafeText.safe_string_contains?("hello world", "xyz") == {:ok, false}
    end

    test "returns error classification for binary data" do
      assert SafeText.safe_string_contains?(<<0, 1, 2>>, "anything") == {:error, :binary_file}
    end

    test "returns error classification for invalid UTF-8" do
      assert SafeText.safe_string_contains?(<<0xFF>>, "x") == {:error, :invalid_utf8}
    end

    test "returns error classification for unsafe text" do
      control_bytes = for _ <- 1..200, into: <<>>, do: <<0x01>>
      text = String.duplicate("a", 3000)
      assert SafeText.safe_string_contains?(control_bytes <> text, "a") == {:error, :unsafe_text}
    end
  end

  # ---------------------------------------------------------------------------
  # safe_slice/2
  # ---------------------------------------------------------------------------

  describe "safe_slice/2" do
    test "slices valid UTF-8 string grapheme-aware" do
      # "café" has 4 graphemes. safe_slice(3) gives "caf"
      assert SafeText.safe_slice("café", 3) == "caf"
    end

    test "slices full string when max chars exceeds length" do
      assert SafeText.safe_slice("hello", 10) == "hello"
    end

    test "returns empty string for invalid UTF-8" do
      assert SafeText.safe_slice(<<0xFF, 0xFE>>, 10) == ""
    end

    test "handles emoji correctly" do
      # "🌍🌎🌏" has 3 graphemes. safe_slice(2) gives "🌍🌎"
      assert SafeText.safe_slice("🌍🌎🌏", 2) == "🌍🌎"
    end

    test "zero chars returns empty" do
      assert SafeText.safe_slice("hello", 0) == ""
    end
  end
end
