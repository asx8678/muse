defmodule Muse.LLM.OpenAI.ChatCompletionsMapper do
  @moduledoc """
  Maps a `Muse.LLM.Request` to an OpenAI Chat Completions JSON payload.

  Produces a JSON-compatible map with only string keys (no debug atom keys),
  suitable for `Jason.encode!/1`. No HTTP client or network dependency.

  ## Usage

      iex> request = %Muse.LLM.Request{model: "gpt-4.1", messages: [Muse.LLM.Message.user("hello")]}
      iex> payload = Muse.LLM.OpenAI.ChatCompletionsMapper.to_payload(request)
      iex> payload["model"]
      "gpt-4.1"
      iex> Jason.encode!(payload) |> Jason.decode!() |> Map.get("model")
      "gpt-4.1"

  """

  alias Muse.LLM.{Message, Request}

  @doc """
  Returns the OpenAI Chat Completions API endpoint path.
  """
  @spec endpoint_path() :: String.t()
  def endpoint_path, do: "/chat/completions"

  @doc """
  Converts a `Muse.LLM.Request` into an OpenAI Chat Completions request payload.

  Returns a map with only JSON-compatible (string) keys, ready for
  `Jason.encode!/1`. Optional fields (`temperature`, `max_tokens`,
  `response_format`, `name`) are included only when non-nil.

  ## Tool handling

  Tool specs produced by `Muse.Tool.Spec.to_provider_schema/1` include an
  atom `:name` key for debug-preview compatibility. This mapper strips
  that key to produce a clean JSON payload.

  When tools are present and `tool_choice` is `nil`, it defaults to `"auto"`.
  """
  @spec to_payload(Request.t()) :: map()
  def to_payload(%Request{} = request) do
    base = %{
      "model" => request.model,
      "messages" => map_messages(request.messages)
    }

    base
    |> maybe_put_tools(request.tools)
    |> maybe_put_tool_choice(request.tools, request.tool_choice)
    |> maybe_put("stream", request.stream)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("max_tokens", request.max_tokens)
    |> maybe_put("response_format", request.response_format)
  end

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  defp map_messages(nil), do: []

  defp map_messages(messages) when is_list(messages) do
    Enum.map(messages, &map_message/1)
  end

  defp map_message(%Message{} = msg) do
    base = %{
      "role" => Atom.to_string(msg.role),
      "content" => msg.content
    }

    base
    |> maybe_put("name", msg.name)
    |> maybe_put("tool_call_id", msg.tool_call_id)
  end

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  defp maybe_put_tools(payload, nil), do: payload
  defp maybe_put_tools(payload, []), do: payload
  defp maybe_put_tools(payload, tools) when is_list(tools) do
    Map.put(payload, "tools", Enum.map(tools, &map_tool/1))
  end

  defp map_tool(tool) when is_map(tool) do
    # Strip debug atom keys (e.g. :name) from tool specs produced by
    # Muse.Tool.Spec.to_provider_schema/1, keeping only JSON-compatible keys.
    tool
    |> Map.drop([:name])
  end

  # ---------------------------------------------------------------------------
  # Tool choice
  # ---------------------------------------------------------------------------

  defp maybe_put_tool_choice(payload, nil, _tool_choice), do: payload
  defp maybe_put_tool_choice(payload, [], _tool_choice), do: payload
  defp maybe_put_tool_choice(payload, _tools, nil), do: Map.put(payload, "tool_choice", "auto")

  defp maybe_put_tool_choice(payload, _tools, :auto),
    do: Map.put(payload, "tool_choice", "auto")

  defp maybe_put_tool_choice(payload, _tools, :none),
    do: Map.put(payload, "tool_choice", "none")

  defp maybe_put_tool_choice(payload, _tools, :required),
    do: Map.put(payload, "tool_choice", "required")

  defp maybe_put_tool_choice(payload, _tools, {:function, name}) when is_binary(name) do
    Map.put(payload, "tool_choice", %{
      "type" => "function",
      "function" => %{"name" => name}
    })
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)
end
