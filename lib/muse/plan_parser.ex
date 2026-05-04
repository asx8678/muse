defmodule Muse.PlanParser do
  @moduledoc """
  Parse raw LLM output text into a validated `%Muse.Plan{}` struct.

  The parser accepts strict JSON text by default. For practical model
  outputs, callers can ask it to extract JSON from fenced code blocks or
  from a single balanced JSON object embedded in surrounding prose.

  ## Pipeline

  1. Extract JSON text (optionally from fenced block)
  2. Decode JSON via `Jason`
  3. Validate via `Muse.PlanSchema.validate/1`
  4. Convert to `%Muse.Plan{}` via `Muse.Plan.from_map/1`

  ## Error handling

  All errors are returned as `{:error, errors}` where `errors` is a list
  of human-readable strings. No exceptions are raised on bad input.

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

  @fenced_json_regex ~r/```(?:json)?\s*\n(.*?)\n\s*```/s

  @doc """
  Parse raw text into a `%Muse.Plan{}` struct.

  ## Options

    * `:fenced` — when `true`, attempt to extract JSON from a fenced
      code block before parsing (default `false`)
    * `:extract` — extraction strategy. Supported values:
      * `:strict` (default) — parse the whole trimmed text as JSON
      * `:fenced` — same as `fenced: true`
      * `:auto` — fenced extraction first, then a single balanced JSON
        object embedded in prose, then strict fallback

  ## Returns

    * `{:ok, %Muse.Plan{}}` — successfully parsed and validated plan
    * `{:error, errors}` — list of error strings
  """
  @spec parse(String.t(), keyword()) :: {:ok, Muse.Plan.t()} | {:error, [String.t()]}
  def parse(text, opts \\ []) when is_binary(text) do
    with {:ok, json_text} <- extract_json(text, opts),
         {:ok, decoded} <- decode_json(json_text),
         {:ok, normalized} <- Muse.PlanSchema.validate(decoded) do
      {:ok, Muse.Plan.from_map(normalized)}
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

  # -- JSON extraction ----------------------------------------------------------

  defp extract_json(text, opts) do
    case Keyword.get(opts, :extract) do
      :auto ->
        extract_auto_json(text)

      :fenced ->
        extract_fenced_json(text)

      :strict ->
        {:ok, String.trim(text)}

      _ ->
        if(Keyword.get(opts, :fenced, false),
          do: extract_fenced_json(text),
          else: {:ok, String.trim(text)}
        )
    end
  end

  defp extract_fenced_json(text) do
    case Regex.run(@fenced_json_regex, text) do
      [_, captured] -> {:ok, String.trim(captured)}
      _ -> {:ok, String.trim(text)}
    end
  end

  defp extract_auto_json(text) do
    case Regex.run(@fenced_json_regex, text) do
      [_, captured] ->
        {:ok, String.trim(captured)}

      _ ->
        case extract_balanced_json_object(text) do
          {:ok, json_text} -> {:ok, String.trim(json_text)}
          :no_match -> {:ok, String.trim(text)}
        end
    end
  end

  defp extract_balanced_json_object(text) do
    text
    |> String.to_charlist()
    |> find_balanced_json_object()
  end

  defp find_balanced_json_object([]), do: :no_match

  defp find_balanced_json_object([?{ | _] = chars),
    do: collect_json_object(chars, [], 0, false, false)

  defp find_balanced_json_object([_char | rest]), do: find_balanced_json_object(rest)

  defp collect_json_object([], _acc, _depth, _in_string?, _escaped?), do: :no_match

  defp collect_json_object([char | rest], acc, depth, in_string?, escaped?) do
    acc = [char | acc]

    cond do
      in_string? and escaped? ->
        collect_json_object(rest, acc, depth, true, false)

      in_string? and char == ?\\ ->
        collect_json_object(rest, acc, depth, true, true)

      in_string? and char == ?\" ->
        collect_json_object(rest, acc, depth, false, false)

      in_string? ->
        collect_json_object(rest, acc, depth, true, false)

      char == ?\" ->
        collect_json_object(rest, acc, depth, true, false)

      char == ?{ ->
        collect_json_object(rest, acc, depth + 1, false, false)

      char == ?} and depth == 1 ->
        {:ok, acc |> Enum.reverse() |> to_string()}

      char == ?} ->
        collect_json_object(rest, acc, depth - 1, false, false)

      true ->
        collect_json_object(rest, acc, depth, false, false)
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
end
