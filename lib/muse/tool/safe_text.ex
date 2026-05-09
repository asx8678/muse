defmodule Muse.Tool.SafeText do
  @moduledoc """
  Central helpers for safe text/binary detection and UTF-8 handling in file tools.

  File tools read raw binary from disk and must validate it before calling
  String functions (which crash on invalid UTF-8). This module provides:

    * `classify/1` — detect binary files, invalid UTF-8, and unsafe text
    * `safe_truncate/2` — truncate at UTF-8 codepoint boundaries
    * `safe_split_lines/1` — split into lines, rejecting invalid UTF-8
    * `safe_string_contains?/2` — pattern search that handles invalid UTF-8

  ## Detection heuristics

  A file is classified as binary/unsafe when any of these hold:

    1. Contains NUL bytes (\\0) — definitive binary indicator
    2. Contains invalid UTF-8 sequences — broken multibyte encodings
    3. Excessive control-character density — too many non-whitespace
       control chars (0x01–0x08, 0x0E–0x1F) in the first 8KB suggests
       binary data (images, compiled objects, etc.)

  ## Design

  All functions return `{:ok, ...}` or `{:error, reason}` — never raise.
  Error messages are structured, bounded, and safe for model consumption.
  """

  @binary_sample_size 8192
  # If >5% of non-whitespace bytes in the sample are control chars, treat as binary
  @control_char_density_threshold 0.05

  @type classification :: :text | :binary_file | :invalid_utf8 | :unsafe_text

  @doc """
  Classify binary data as text or one of several unsafe categories.

  Examines the first `@binary_sample_size` bytes (or fewer if the data
  is shorter). Returns:

    * `:text` — valid UTF-8, no NUL bytes, acceptable control-char density
    * `:binary_file` — contains NUL bytes
    * `:invalid_utf8` — broken UTF-8 sequences (no NUL bytes)
    * `:unsafe_text` — valid UTF-8 but excessive control-character density

  ## Examples

      iex> Muse.Tool.SafeText.classify("hello world")
      :text

      iex> Muse.Tool.SafeText.classify(<<0, 1, 2>>)
      :binary_file

      iex> Muse.Tool.SafeText.classify(<<0xFF, 0xFE>>)
      :invalid_utf8
  """
  @spec classify(binary()) :: classification()
  def classify(<<>>) do
    :text
  end

  def classify(data) when is_binary(data) do
    sample_size = min(byte_size(data), @binary_sample_size)
    <<sample::binary-size(sample_size), _::binary>> = data

    cond do
      # NUL bytes → definitive binary
      :binary.match(sample, <<0>>) != :nomatch ->
        :binary_file

      # Invalid UTF-8 sequences
      not String.valid?(sample) ->
        :invalid_utf8

      # Excessive control characters
      unsafe_control_density?(sample) ->
        :unsafe_text

      true ->
        :text
    end
  end

  @doc """
  Truncate binary data at a UTF-8 codepoint boundary.

  Unlike `binary_part/3`, this function never slices through a multibyte
  UTF-8 sequence. If `max_bytes` falls inside a multibyte sequence, the
  truncation point is moved back to the last valid codepoint boundary.

  Returns `{:ok, truncated_binary}` where `truncated_binary` is valid UTF-8.

  ## Examples

      iex> Muse.Tool.SafeText.safe_truncate("hello world", 5)
      {:ok, "hello"}

      iex> Muse.Tool.SafeText.safe_truncate("café", 4)
      {:ok, "caf"}

      iex> Muse.Tool.SafeText.safe_truncate("abc", 100)
      {:ok, "abc"}
  """
  @spec safe_truncate(binary(), non_neg_integer()) :: {:ok, binary()}
  def safe_truncate(data, max_bytes)
      when is_binary(data) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(data) <= max_bytes do
      {:ok, data}
    else
      # Walk back from max_bytes to find a valid UTF-8 boundary.
      # A UTF-8 continuation byte has the pattern 10xxxxxx (0x80–0xBF).
      # We find the last byte at or before max_bytes that is NOT a
      # continuation byte, which means it's a valid start or single-byte.
      truncated = find_utf8_boundary(data, max_bytes)
      {:ok, truncated}
    end
  end

  @doc """
  Split binary data into lines, validating UTF-8 first.

  Returns `{:ok, lines}` if the data is valid text, or `{:error, reason}`
  if the data is binary, invalid UTF-8, or unsafe text.

  The `reason` is a human-readable string suitable for model consumption.
  """
  @spec safe_split_lines(binary()) :: {:ok, [String.t()]} | {:error, String.t()}
  def safe_split_lines(data) when is_binary(data) do
    case classify(data) do
      :text ->
        {:ok, String.split(data, "\n")}

      :binary_file ->
        {:error, "binary files are not supported"}

      :invalid_utf8 ->
        {:error, "file contains invalid UTF-8 and cannot be displayed as text"}

      :unsafe_text ->
        {:error, "file contains excessive control characters and may be binary"}
    end
  end

  @doc """
  Check if `pattern` occurs in `data`, validating UTF-8 first.

  Returns `{:ok, boolean}` if the data is valid text, or `{:error, classification}`
  if the data is binary/unsafe. The caller can decide whether to skip the file.

  This is designed for `repo_search` which silently skips binary files rather
  than returning errors.
  """
  @spec safe_string_contains?(binary(), String.t()) ::
          {:ok, boolean()} | {:error, classification()}
  def safe_string_contains?(data, pattern) when is_binary(data) and is_binary(pattern) do
    case classify(data) do
      :text ->
        {:ok, String.contains?(data, pattern)}

      other ->
        {:error, other}
    end
  end

  @doc """
  Safely slice a string to at most `max_chars` graphemes, ensuring valid UTF-8.

  Unlike `binary_part`, this uses grapheme-aware slicing so it never
  splits a multibyte character. If the input is not valid UTF-8, returns
  an empty string rather than crashing.
  """
  @spec safe_slice(String.t(), non_neg_integer()) :: String.t()
  def safe_slice(string, max_chars)
      when is_binary(string) and is_integer(max_chars) and max_chars >= 0 do
    if String.valid?(string) do
      String.slice(string, 0, max_chars)
    else
      ""
    end
  end

  # -- Private helpers -----------------------------------------------------------

  # Check if the sample has excessive control-character density.
  # Control chars we check: 0x01–0x08, 0x0E–0x1F (excluding \t=0x09, \n=0x0A,
  # \v=0x0B, \f=0x0C, \r=0x0D which are legitimate whitespace).
  # We skip 0x7F (DEL) — extremely rare in text but could appear; we treat it
  # as a control character too.
  defp unsafe_control_density?(sample) do
    # Only check first 8KB
    check_size = min(byte_size(sample), @binary_sample_size)
    <<check::binary-size(check_size), _::binary>> = sample

    total = byte_size(check)
    # Avoid division by zero for very small samples
    if total < 10 do
      false
    else
      control_count = count_control_chars(check, 0)
      control_count / total > @control_char_density_threshold
    end
  end

  # Count control characters in a binary using binary pattern matching.
  # Control chars: 0x01–0x08, 0x0E–0x1F, 0x7F
  # Skip: 0x00 (NUL — already caught by classify), 0x09–0x0D (whitespace),
  # 0x20+ (printable ASCII / multibyte UTF-8).
  defp count_control_chars(<<>>, acc), do: acc

  # NUL (0x00) — already caught, skip counting here for efficiency
  defp count_control_chars(<<0x00, rest::binary>>, acc), do: count_control_chars(rest, acc)

  # Whitespace: HT, LF, VT, FF, CR (0x09–0x0D)
  defp count_control_chars(<<0x09, rest::binary>>, acc), do: count_control_chars(rest, acc)
  defp count_control_chars(<<0x0A, rest::binary>>, acc), do: count_control_chars(rest, acc)
  defp count_control_chars(<<0x0B, rest::binary>>, acc), do: count_control_chars(rest, acc)
  defp count_control_chars(<<0x0C, rest::binary>>, acc), do: count_control_chars(rest, acc)
  defp count_control_chars(<<0x0D, rest::binary>>, acc), do: count_control_chars(rest, acc)

  # Control chars: 0x01–0x08
  defp count_control_chars(<<c, rest::binary>>, acc) when c in 0x01..0x08 do
    count_control_chars(rest, acc + 1)
  end

  # Non-whitespace control chars: 0x0E–0x1F
  defp count_control_chars(<<c, rest::binary>>, acc) when c in 0x0E..0x1F do
    count_control_chars(rest, acc + 1)
  end

  # DEL (0x7F)
  defp count_control_chars(<<0x7F, rest::binary>>, acc), do: count_control_chars(rest, acc + 1)

  # Multibyte UTF-8 continuation byte (0x80–0xBF) — not a control char
  defp count_control_chars(<<c, rest::binary>>, acc) when c in 0x80..0xBF do
    count_control_chars(rest, acc)
  end

  # Multibyte UTF-8 lead bytes (0xC0–0xFF) — not a control char
  defp count_control_chars(<<c, rest::binary>>, acc) when c in 0xC0..0xFF do
    count_control_chars(rest, acc)
  end

  # Printable ASCII (0x20–0x7E) and anything else — not a control char
  defp count_control_chars(<<_, rest::binary>>, acc), do: count_control_chars(rest, acc)

  # Find a valid UTF-8 boundary by walking backward from max_bytes.
  #
  # Walk backward past continuation bytes (0x80–0xBF) until we find a
  # non-continuation byte. If it's ASCII (0x00–0x7F), it's a valid truncation
  # point. If it's a multibyte lead byte, check whether the full sequence
  # fits within max_bytes:
  #   - If it fits, include the sequence (truncate at max_bytes)
  #   - If not, exclude the lead byte (truncate before it)
  defp find_utf8_boundary(data, max_bytes) do
    pos = min(max_bytes, byte_size(data))
    find_boundary(data, pos, max_bytes)
  end

  defp find_boundary(_data, 0, _max_bytes), do: <<>>

  defp find_boundary(data, pos, max_bytes) do
    byte = :binary.at(data, pos - 1)

    cond do
      # Continuation byte — keep walking back
      byte in 0x80..0xBF ->
        find_boundary(data, pos - 1, max_bytes)

      # ASCII byte — valid truncation point
      byte <= 0x7F ->
        binary_part(data, 0, pos)

      # Multibyte lead byte — check if the full sequence fits
      true ->
        n = utf8_sequence_length(byte)

        if pos + n - 1 <= max_bytes do
          # Full sequence fits — include it
          binary_part(data, 0, max_bytes)
        else
          # Sequence doesn't fit — exclude the incomplete lead byte
          binary_part(data, 0, pos - 1)
        end
    end
  end

  # UTF-8 sequence length from the lead byte
  defp utf8_sequence_length(b) when b in 0xC0..0xDF, do: 2
  defp utf8_sequence_length(b) when b in 0xE0..0xEF, do: 3
  defp utf8_sequence_length(b) when b in 0xF0..0xF7, do: 4
  defp utf8_sequence_length(_b), do: 1
end
