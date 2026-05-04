defmodule Muse.PlanParser do
  @moduledoc """
  Parse raw LLM output text into a validated `%Muse.Plan{}` struct.

  The parser accepts strict JSON text by default. It can also handle
  practical model outputs when the `extract` option is set:

    * `:strict` (default) — expects the entire text to be valid JSON
    * `:fenced`           — extracts JSON from a fenced code block
                            (e.g. ```` ```json ... ``` ````); falls back
                            to raw text if no fence is found
    * `:auto`            — tries strict JSON first, then fenced extraction,
                          then prose-with-JSON extraction (finds a single
                          top-level JSON object surrounded by prose)

  The legacy `fenced: true` option is preserved for backward compatibility
  and is equivalent to `extract: :fenced`.

  ## Pipeline

  1. Extract JSON text (strategy depends on `extract` option)
  2. Decode JSON via `Jason`
  3. Validate via `Muse.PlanSchema.validate/1`
  4. Convert to `%Muse.Plan{}` via `Muse.Plan.from_map/1`

  ## Error handling

  All errors are returned as `{:error, errors}` where `errors` is a list
  of human-readable strings. No exceptions are raised on bad input.
  Error messages are redacted: they never echo large raw LLM output or
  potential secrets. Long error messages are truncated to 200 characters.

  ## Repair prompt

  When a plan fails to parse, `repair_prompt/2` generates a one-shot
  prompt that the conductor can send back to the model for a repair
  attempt. This module does **not** perform model calls itself.

  ## Examples

      iex> json = ~s({"objective": "Add /version", "tasks": [{"title": "Add cmd", "description": "Update commands.ex"}]})
      iex> {:ok, %Muse.Plan{}} = Muse.PlanParser.parse(json)

      iex> Muse.PlanParser.parse("not json at all")
      {:error, ["JSON decode error: ..."]}

  """

  @max_error_length 200

  @fenced_json_regex ~r/```(?:json)?\s*\n(.*?)\n\s*```/s

  @doc """
  Parse raw text into a `%Muse.Plan{}` struct.

  ## Options

    * `:extract` — extraction strategy (default `:strict`)
      - `:strict` — expects the entire text to be valid JSON
      - `:fenced`  — extracts JSON from a fenced code block; falls back
                      to raw text if no fence is found
      - `:auto`   — tries strict, then fenced, then prose-with-JSON
    * `:fenced` — when `true`, equivalent to `extract: :fenced`
      (backward compatible; `:extract` takes precedence if both given)

  ## Returns

    * `{:ok, %Muse.Plan{}}` — successfully parsed and validated plan
    * `{:error, errors}` — list of redacted error strings
  """
  @spec parse(String.t(), keyword()) :: {:ok, Muse.Plan.t()} | {:error, [String.t()]}
  def parse(text, opts \\ []) when is_binary(text) do
    extract_mode = resolve_extract_mode(opts)

    with {:ok, json_text} <- extract_json(text, extract_mode),
         {:ok, decoded} <- decode_json(json_text),
         {:ok, normalized} <- Muse.PlanSchema.validate(decoded) do
      {:ok, Muse.Plan.from_map(normalized)}
    else
      {:error, errors} -> {:error, Enum.map(errors, &redact_error/1)}
    end
  end

  @doc """
  Generate a repair prompt for invalid plan output.

  This is intended to be called by the conductor when a plan fails
  validation. The returned string can be sent as a follow-up message
  to the model for a one-shot repair attempt.

  ## Options

    * `:max_retries` — hint about remaining retries (included in prompt)
    * `:errors` — the error list from parse (used to build the prompt)

  ## Example

      iex> Muse.PlanParser.repair_prompt("bad json", errors: ["JSON decode error: unexpected byte"])
      "The previous plan output was invalid. Please fix the following issues and output a valid JSON plan:\\n\\n- JSON decode error: unexpected byte\\n\\nEnsure the plan is valid JSON matching the structured plan schema..."
  """
  @spec repair_prompt(String.t(), keyword()) :: String.t()
  def repair_prompt(_original_text, opts \\ []) do
    errors = Keyword.get(opts, :errors, [])
    max_retries = Keyword.get(opts, :max_retries, 1)

    error_lines =
      case errors do
        [] -> ["- Unknown error"]
        _ -> Enum.map(errors, &("- " <> &1))
      end

    """
    The previous plan output was invalid. Please fix the following issues and output a valid JSON plan:

    #{Enum.join(error_lines, "\n")}

    Ensure the plan is valid JSON matching the structured plan schema:
    - "objective" (string, required)
    - "tasks" (array, required, non-empty) — each task must have "title" and "description" (strings)
    - "requires_write" and "requires_shell" must be booleans
    - "risks" must be a list of strings
    #{if max_retries <= 1, do: "This is your last retry attempt.", else: "You have #{max_retries} retries remaining."}
    """
    |> String.trim()
  end

  # -- Extract mode resolution --------------------------------------------------

  defp resolve_extract_mode(opts) do
    cond do
      Keyword.has_key?(opts, :extract) -> Keyword.get(opts, :extract, :strict)
      Keyword.get(opts, :fenced, false) -> :fenced
      true -> :strict
    end
  end

  # -- JSON extraction ----------------------------------------------------------

  defp extract_json(text, :strict) do
    {:ok, String.trim(text)}
  end

  defp extract_json(text, :fenced) do
    case Regex.run(@fenced_json_regex, text) do
      [_, captured] -> {:ok, captured}
      _ -> {:ok, String.trim(text)}
    end
  end

  defp extract_json(text, :auto) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "{") do
      case decode_json(trimmed) do
        {:ok, _} -> {:ok, trimmed}
        {:error, _} -> try_fenced_then_prose(text)
      end
    else
      try_fenced_then_prose(text)
    end
  end

  defp try_fenced_then_prose(text) do
    case Regex.run(@fenced_json_regex, text) do
      [_, captured] ->
        {:ok, captured}

      _ ->
        case extract_prose_json(text) do
          {:ok, json_text} -> {:ok, json_text}
          :no_match -> {:ok, String.trim(text)}
        end
    end
  end

  # Find a single top-level JSON object embedded in prose text.
  # Walks the text character-by-character to find the first balanced
  # top-level JSON object, respecting string literals so braces inside
  # strings don't affect the depth counter.
  defp extract_prose_json(text) do
    case find_first_balanced_object(text) do
      {:ok, json_fragment} -> {:ok, json_fragment}
      :no_match -> :no_match
    end
  end

  defp find_first_balanced_object(text) do
    case find_opening_brace(text, 0) do
      {:ok, start_pos} ->
        case walk_to_closing_brace(text, start_pos + 1, 1) do
          {:ok, end_pos} ->
            fragment = String.slice(text, start_pos, end_pos - start_pos + 1)

            case Jason.decode(fragment) do
              {:ok, decoded} when is_map(decoded) -> {:ok, fragment}
              _ -> :no_match
            end

          :no_match ->
            :no_match
        end

      :no_match ->
        :no_match
    end
  end

  defp find_opening_brace(text, pos) do
    case String.at(text, pos) do
      nil -> :no_match
      "{" -> {:ok, pos}
      "\"" -> find_opening_brace(text, skip_string_literal(text, pos + 1))
      _ -> find_opening_brace(text, pos + 1)
    end
  end

  defp skip_string_literal(text, pos) do
    case String.at(text, pos) do
      nil -> pos
      "\\" -> skip_string_literal(text, pos + 2)
      "\"" -> pos + 1
      _ -> skip_string_literal(text, pos + 1)
    end
  end

  defp walk_to_closing_brace(text, pos, depth) do
    case String.at(text, pos) do
      nil ->
        :no_match

      "{" ->
        walk_to_closing_brace(text, pos + 1, depth + 1)

      "}" ->
        if depth - 1 == 0 do
          {:ok, pos}
        else
          walk_to_closing_brace(text, pos + 1, depth - 1)
        end

      "\"" ->
        end_pos = skip_string_literal(text, pos + 1)
        walk_to_closing_brace(text, end_pos, depth)

      _ ->
        walk_to_closing_brace(text, pos + 1, depth)
    end
  end

  # -- JSON decoding ------------------------------------------------------------

  defp decode_json(text) do
    case Jason.decode(text) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, ["JSON decoded to a non-object value (expected a JSON object)"]}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, ["JSON decode error: #{Exception.message(error)}"]}
    end
  end

  # -- Error redaction ----------------------------------------------------------

  defp redact_error(error) when is_binary(error) do
    error
    |> String.slice(0, @max_error_length)
    |> maybe_add_ellipsis()
  end

  defp redact_error(error), do: redact_error(to_string(error))

  defp maybe_add_ellipsis(error) do
    if String.length(error) >= @max_error_length do
      error <> "... [truncated]"
    else
      error
    end
  end
end
