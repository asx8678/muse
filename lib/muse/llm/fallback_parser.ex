defmodule Muse.LLM.FallbackParser do
  @moduledoc """
  Extracts pseudo-JSON textual tool calls emitted by models that do not
  support the native `tool_calls` array (e.g. some reasoning models via
  OpenRouter) and injects them as structured `Muse.LLM.ToolCall` structs
  into the response.
  """

  alias Muse.LLM.Response
  alias Muse.LLM.ToolCall

  @doc "Extracts pseudo-JSON textual tool calls into structured ToolCall structs."
  def parse(%Response{} = response) do
    content = response.content || ""

    textual_tools = extract_tools(content)

    if textual_tools == [] do
      response
    else
      # Append to existing tool calls if any
      existing = response.tool_calls || []
      %{response | tool_calls: existing ++ textual_tools}
    end
  end

  defp extract_tools(content) do
    # Match both standard `<tool_call>name{...}` and deeper `<tool_call>name{...}(...)` formats
    regex = ~r/<tool_call>\s*([A-Za-z0-9_]+)\s*\{([^}]+)\}/

    Regex.scan(regex, content)
    |> Enum.map(fn [_, raw_name, raw_args] ->
      name = String.trim(raw_name)
      args = parse_args(String.trim(raw_args))

      ToolCall.new(name, args, id: "fallback_" <> Base.encode16(:crypto.strong_rand_bytes(4)))
    end)
  end

  defp parse_args(raw_args) do
    # First try strict JSON if the model emitted valid JSON payload,
    # otherwise fallback to loose key:value extraction
    case Jason.decode("{" <> raw_args <> "}") do
      {:ok, map} ->
        map

      {:error, _} ->
        raw_args
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
end
