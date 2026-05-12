defmodule Muse.LLM.FallbackParser do
  @moduledoc """
  Extracts textual tool calls emitted by models that do not support the
  native `tool_calls` array (e.g. reasoning models via OpenRouter, DeepSeek,
  Qwen, GLM, Kimi, etc.) and injects them as structured
  `Muse.LLM.ToolCall` structs into the response.

  Handles six common fallback formats:

  1. XML Tool Call with JSON payload (DeepSeek/GLM)
  2. Pseudo-JSON without parens (Gemini/OpenRouter, ◈name{...})
  3. ReAct style (Qwen/older models)
  4. Raw Markdown JSON blocks
  5. Invocations with parens (◈name(...)) — supports JSON objects,
     keyword args (key="val"), and loose key:value pairs inside parens
  6. Space-separated arguments (◈name arg1 arg2) — maps positional
     args intelligently: single path, number+path, or multiple parts
  """

  alias Muse.LLM.Response
  alias Muse.LLM.ToolCall

  @doc "Extracts textual tool calls into structured ToolCall structs."
  def parse(%Response{} = response) do
    content = response.content || ""

    tools =
      Enum.concat([
        extract_xml_json(content),
        extract_markdown_json(content),
        extract_react(content),
        extract_pseudo_json(content),
        extract_invocations(content),
        extract_space_separated(content)
      ])
      |> Enum.uniq_by(&{&1.name, &1.arguments})

    if tools == [] do
      response
    else
      existing = response.tool_calls || []
      %{response | tool_calls: existing ++ tools}
    end
  end

  # --- Format 1: XML Tool Call with JSON payload ---

  defp extract_xml_json(content) do
    ~r/<tool_call>(.*?)<\/tool_call>/s
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_, inner] ->
      inner
      |> String.trim()
      |> try_parse_standard_json()
    end)
  end

  # --- Format 4: Raw Markdown JSON blocks ---

  defp extract_markdown_json(content) do
    ~r/```(?:json)?\s*(.*?)\s*```/s
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_, inner] ->
      json_str = String.trim(inner)

      if String.contains?(json_str, "\"name\"") and String.contains?(json_str, "\"arguments\"") do
        try_parse_standard_json(json_str)
      else
        []
      end
    end)
  end

  # --- Format 3: ReAct style ---

  defp extract_react(content) do
    ~r/Action:\s*([A-Za-z0-9_]+).*?Action Input:\s*(.+?)(?=\n\n|\nAction:|$)/s
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_, name, input_str] ->
      input_str
      |> String.trim()
      |> try_parse_react_json(name)
    end)
  end

  defp try_parse_react_json(input_str, name) do
    # Try the full string first
    case Jason.decode(input_str) do
      {:ok, args} when is_map(args) ->
        [make_tool(name, args)]

      _ ->
        # If that fails, try extracting a balanced brace object
        case extract_balanced_braces(input_str) do
          nil ->
            # Fallback to loose key:value parsing
            args = parse_loose_args(input_str)
            [make_tool(name, args)]

          json_str ->
            case Jason.decode(json_str) do
              {:ok, args} when is_map(args) -> [make_tool(name, args)]
              _ -> []
            end
        end
    end
  end

  # --- Format 5: Invocations (<tool_call>name(...)) ---
  # Handles three inner formats:
  #   ◈name({"key":"val"})     — JSON object
  #   ◈name(key="val")          — keyword args (double/single/bare quotes)
  #   ◈name(key:val)            — loose key:value (same as pseudo-JSON)
  defp extract_invocations(content) do
    ~r/<tool_call>\s*([A-Za-z0-9_]+)\s*\((.+?)\)/s
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_, name, inner] ->
      args = inner |> String.trim() |> parse_paren_content()
      if map_size(args) > 0, do: [make_tool(name, args)], else: []
    end)
  end

  defp parse_paren_content(inner) do
    cond do
      String.starts_with?(inner, "{") ->
        case Jason.decode(inner) do
          {:ok, args} when is_map(args) -> args
          _ -> %{}
        end

      String.contains?(inner, "=") ->
        parse_keyword_args(inner)

      true ->
        parse_loose_args(inner)
    end
  end

  defp parse_keyword_args(inner) do
    inner
    |> String.split(",", trim: true)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [k, v] ->
          clean_k = k |> String.trim()
          clean_v = v |> String.trim() |> String.trim("\"") |> String.trim("'")
          Map.put(acc, clean_k, clean_v)

        _ ->
          acc
      end
    end)
  end

  # Space-separated key=value pairs (no commas), e.g. "path=/tmp/foo max_lines=50"
  defp parse_space_keyword_args(inner) do
    inner
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(%{}, fn token, acc ->
      case String.split(token, "=", parts: 2) do
        [k, v] ->
          clean_k = k |> String.trim()
          clean_v = v |> String.trim() |> String.trim("\"") |> String.trim("'")
          Map.put(acc, clean_k, clean_v)

        _ ->
          acc
      end
    end)
  end

  # --- Format 6: Space-separated arguments (◈name arg1 arg2) ---

  defp extract_space_separated(content) do
    # Match ◈name followed by non-empty content on the same line
    # that is NOT wrapped in (...) or {...}
    ~r/<tool_call>\s*([A-Za-z0-9_]+)\s+([^\n<]+)/
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_, name, rest] ->
      trimmed = String.trim(rest)

      # Skip if this looks like it has parens/braces (handled by other extractors)
      cond do
        String.starts_with?(trimmed, "(") or String.starts_with?(trimmed, "{") ->
          []

        String.contains?(trimmed, "=") ->
          # keyword args like key=val (space-separated, not comma-separated)
          args = parse_space_keyword_args(trimmed)
          if map_size(args) > 0, do: [make_tool(name, args)], else: []

        true ->
          # Space-separated arguments
          parts = String.split(trimmed, ~r/\s+/, trim: true)
          args = build_positional_args(name, parts)
          if map_size(args) > 0, do: [make_tool(name, args)], else: []
      end
    end)
  end

  defp build_positional_args(_name, parts) do
    non_numeric = Enum.reject(parts, &String.match?(&1, ~r/^\d+$/))
    numeric = Enum.filter(parts, &String.match?(&1, ~r/^\d+$/))

    cond do
      # One non-numeric part plus a number (e.g. "6 /path/to/file.ex" or "/path 6")
      length(non_numeric) == 1 and length(parts) > 1 ->
        path = hd(non_numeric)
        num = hd(numeric)
        %{"path" => path, "max_lines" => num}

      # Single non-numeric argument (likely a path)
      length(non_numeric) == 1 ->
        %{"path" => hd(non_numeric)}

      # Multiple non-numeric parts — join them as a path
      length(non_numeric) > 1 ->
        %{"path" => Enum.join(non_numeric, " ")}

      # Only numeric parts — not enough to form meaningful args
      true ->
        %{}
    end
  end

  # --- Format 2: Pseudo-JSON ---

  defp extract_pseudo_json(content) do
    # Find all occurrences of <tool_call>name{ and extract balanced braces
    matches = Regex.scan(~r/<tool_call>\s*([A-Za-z0-9_]+)\s*\{/s, content)
    positions = find_match_positions(content, matches, 0, [])

    Enum.flat_map(positions, fn {pos, name} ->
      rest = binary_part(content, pos, byte_size(content) - pos)

      case extract_balanced_braces(rest) do
        nil ->
          []

        raw_args ->
          inner = String.slice(raw_args, 1..-2//1)
          args = parse_loose_args(inner)
          [make_tool(name, args)]
      end
    end)
  end

  defp find_match_positions(_content, [], _offset, acc), do: Enum.reverse(acc)

  defp find_match_positions(content, [[match, name] | rest], offset, acc) do
    search_area = binary_part(content, offset, byte_size(content) - offset)

    case :binary.match(search_area, match) do
      :nomatch ->
        find_match_positions(content, rest, offset, acc)

      {rel_pos, match_len} ->
        abs_pos = offset + rel_pos
        # The opening brace is the last character of the match
        brace_pos = abs_pos + match_len - 1
        find_match_positions(content, rest, abs_pos + match_len, [{brace_pos, name} | acc])
    end
  end

  # --- Shared helpers ---

  defp try_parse_standard_json(json_str) do
    case Jason.decode(json_str) do
      {:ok, %{"name" => name, "arguments" => args}} when is_binary(name) and is_map(args) ->
        [make_tool(name, args)]

      _ ->
        []
    end
  end

  defp parse_loose_args(inner) do
    # Try valid JSON first (handles nested objects, quoted keys, etc.)
    case Jason.decode("{" <> inner <> "}") do
      {:ok, map} when is_map(map) ->
        map

      _ ->
        inner
        |> String.split(",", trim: true)
        |> Enum.reduce(%{}, fn pair, acc ->
          case String.split(pair, ":", parts: 2) do
            [k, v] ->
              clean_k =
                k
                |> String.trim()
                |> String.trim("\"")
                |> String.trim("'")

              clean_v =
                v
                |> String.trim()
                |> String.trim("\"")
                |> String.trim("'")

              Map.put(acc, clean_k, clean_v)

            _ ->
              acc
          end
        end)
    end
  end

  # Extracts a balanced brace substring starting at the beginning of `str`.
  # Returns the full substring including outer braces, or nil.
  defp extract_balanced_braces(str) when is_binary(str) do
    if not String.starts_with?(str, "{") do
      nil
    else
      do_extract_braces(str, 0, "")
    end
  end

  defp do_extract_braces(<<char, rest::binary>>, depth, acc) do
    new_acc = acc <> <<char>>

    new_depth =
      cond do
        char == ?{ -> depth + 1
        char == ?} -> depth - 1
        true -> depth
      end

    if new_depth == 0 do
      new_acc
    else
      do_extract_braces(rest, new_depth, new_acc)
    end
  end

  defp do_extract_braces("", _depth, _acc), do: nil

  defp make_tool(name, args) do
    ToolCall.new(name, args, id: "fallback_" <> Base.encode16(:crypto.strong_rand_bytes(4)))
  end
end
