defmodule Muse.LLM.OpenAI.ChatCompletionsDecoder do
  @moduledoc """
  Decodes OpenAI-compatible Chat Completions non-streaming responses.

  This module is intentionally pure: it accepts an already-decoded provider JSON
  body and returns Muse's provider-neutral `%Muse.LLM.Response{}` struct. It does
  not perform HTTP, retries, logging, or telemetry.
  """

  alias Muse.EventPayloadRedactor
  alias Muse.LLM.{Response, ToolCall}

  @max_error_message_length 300

  @known_atom_keys %{
    "arguments" => :arguments,
    "choices" => :choices,
    "completion_tokens" => :completion_tokens,
    "content" => :content,
    "finish_reason" => :finish_reason,
    "function" => :function,
    "id" => :id,
    "message" => :message,
    "name" => :name,
    "prompt_tokens" => :prompt_tokens,
    "tool_calls" => :tool_calls,
    "total_tokens" => :total_tokens,
    "usage" => :usage
  }

  @usage_keys [
    {"prompt_tokens", :prompt_tokens},
    {"completion_tokens", :completion_tokens},
    {"total_tokens", :total_tokens}
  ]

  @doc """
  Decode an OpenAI-compatible Chat Completions response body.

  Returns `{:ok, %Muse.LLM.Response{}}` for a valid non-streaming response, or
  `{:error, reason}` for malformed provider payloads. Error reasons are bounded
  and do not include the raw provider body.
  """
  @spec decode(map()) :: {:ok, Response.t()} | {:error, term()}
  def decode(body) when is_map(body) do
    with {:ok, choice} <- first_choice(body),
         {:ok, message} <- required_map(choice, "message", "choices[0].message"),
         {:ok, tool_calls} <- decode_tool_calls(message),
         {:ok, content} <- decode_content(message, tool_calls),
         {:ok, finish_reason} <- decode_finish_reason(choice),
         {:ok, usage} <- decode_usage(body),
         {:ok, id} <- decode_id(body) do
      {:ok,
       Response.new(
         id: id,
         content: content,
         text: content,
         tool_calls: tool_calls,
         usage: usage,
         finish_reason: finish_reason,
         raw: body
       )}
    end
  end

  def decode(_body) do
    error(:invalid_response, "expected Chat Completions response body to be a map")
  end

  # ---------------------------------------------------------------------------
  # Response shape
  # ---------------------------------------------------------------------------

  defp first_choice(body) do
    case fetch_known(body, "choices") do
      :error ->
        error(:invalid_response, "missing required field choices")

      {:ok, [choice | _]} when is_map(choice) ->
        {:ok, choice}

      {:ok, [_choice | _]} ->
        error(:invalid_response, "malformed choices[0]: expected map")

      {:ok, []} ->
        error(:invalid_response, "malformed choices: expected non-empty list")

      {:ok, _other} ->
        error(:invalid_response, "malformed choices: expected non-empty list")
    end
  end

  defp decode_content(message, tool_calls) do
    case fetch_known(message, "content") do
      :error when tool_calls == [] ->
        # Check for reasoning_content before erroring — reasoning models
        # (e.g. GLM-5.1) may produce reasoning_content with no content when
        # the token budget is exhausted during the thinking phase.
        if reasoning_content_present?(message) do
          error(
            :provider_empty_response,
            "reasoning model produced reasoning_content but no final content; " <>
              "consider increasing max_tokens or using a non-reasoning model"
          )
        else
          error(:invalid_response, "missing required field choices[0].message.content")
        end

      :error ->
        {:ok, nil}

      {:ok, content} when is_binary(content) and content != "" ->
        {:ok, content}

      {:ok, ""} when tool_calls == [] ->
        # Empty string content with no tool calls — check if reasoning was
        # present to give an actionable error instead of returning empty success.
        if reasoning_content_present?(message) do
          error(
            :provider_empty_response,
            "reasoning model produced reasoning_content but empty final content; " <>
              "consider increasing max_tokens or using a non-reasoning model"
          )
        else
          # Non-reasoning model returned empty content — still an error
          error(
            :invalid_response,
            "malformed choices[0].message.content: expected non-empty string unless tool_calls are present"
          )
        end

      {:ok, ""} ->
        # Empty content with tool_calls present — acceptable (tool_calls carry the response)
        {:ok, ""}

      {:ok, content} when is_binary(content) ->
        {:ok, content}

      {:ok, nil} when tool_calls != [] ->
        {:ok, nil}

      {:ok, nil} ->
        # Nil content with no tool calls — check reasoning_content
        if reasoning_content_present?(message) do
          error(
            :provider_empty_response,
            "reasoning model produced reasoning_content but nil final content; " <>
              "consider increasing max_tokens or using a non-reasoning model"
          )
        else
          error(
            :invalid_response,
            "malformed choices[0].message.content: expected string unless tool_calls are present"
          )
        end

      {:ok, _other} ->
        error(:invalid_response, "malformed choices[0].message.content: expected string or nil")
    end
  end

  # Check if the message contains reasoning_content (used by reasoning models
  # like GLM-5.1, DeepSeek-R1). This field is not in @known_atom_keys because
  # it is provider-specific, but we check both string and atom forms.
  defp reasoning_content_present?(message) when is_map(message) do
    case Map.get(message, "reasoning_content") || Map.get(message, :reasoning_content) do
      content when is_binary(content) and content != "" -> true
      _other -> false
    end
  end

  defp decode_finish_reason(choice) do
    case fetch_known(choice, "finish_reason") do
      :error ->
        {:ok, nil}

      {:ok, finish_reason} when is_binary(finish_reason) or is_nil(finish_reason) ->
        {:ok, finish_reason}

      {:ok, _other} ->
        error(:invalid_response, "malformed choices[0].finish_reason: expected string or nil")
    end
  end

  defp decode_id(body) do
    case fetch_known(body, "id") do
      :error ->
        {:ok, nil}

      {:ok, id} when is_binary(id) or is_nil(id) ->
        {:ok, id}

      {:ok, _other} ->
        error(:invalid_response, "malformed id: expected string or nil")
    end
  end

  # ---------------------------------------------------------------------------
  # Usage
  # ---------------------------------------------------------------------------

  defp decode_usage(body) do
    case fetch_known(body, "usage") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, usage} when is_map(usage) ->
        {:ok, normalize_usage(usage)}

      {:ok, _other} ->
        error(:invalid_response, "malformed usage: expected map or nil")
    end
  end

  defp normalize_usage(usage) do
    usage
    |> Enum.reject(fn {key, _value} -> known_usage_key?(key) end)
    |> Enum.reduce(normalized_known_usage(usage), fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp normalized_known_usage(usage) do
    Enum.reduce(@usage_keys, %{}, fn {string_key, atom_key}, acc ->
      cond do
        Map.has_key?(usage, string_key) ->
          Map.put(acc, atom_key, Map.fetch!(usage, string_key))

        Map.has_key?(usage, atom_key) ->
          Map.put(acc, atom_key, Map.fetch!(usage, atom_key))

        true ->
          acc
      end
    end)
  end

  defp known_usage_key?(key) do
    Enum.any?(@usage_keys, fn {string_key, atom_key} -> key == string_key or key == atom_key end)
  end

  # ---------------------------------------------------------------------------
  # Tool calls
  # ---------------------------------------------------------------------------

  defp decode_tool_calls(message) do
    case fetch_known(message, "tool_calls") do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, tool_calls} when is_list(tool_calls) ->
        tool_calls
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {tool_call, index}, {:ok, acc} ->
          case decode_tool_call(tool_call, index) do
            {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _other} ->
        error(:invalid_response, "malformed choices[0].message.tool_calls: expected list or nil")
    end
  end

  defp decode_tool_call(tool_call, index) when is_map(tool_call) do
    path = "choices[0].message.tool_calls[#{index}]"

    with {:ok, id} <- decode_tool_call_id(tool_call, path),
         {:ok, function} <-
           required_map(tool_call, "function", "#{path}.function", :invalid_tool_call),
         {:ok, name} <- decode_tool_name(function, "#{path}.function.name"),
         {:ok, arguments} <- decode_tool_arguments(function, "#{path}.function.arguments") do
      {:ok, ToolCall.new(name, arguments, id: id, raw: tool_call)}
    end
  end

  defp decode_tool_call(_tool_call, index) do
    error(:invalid_tool_call, "malformed choices[0].message.tool_calls[#{index}]: expected map")
  end

  defp decode_tool_call_id(tool_call, path) do
    case fetch_known(tool_call, "id") do
      :error ->
        {:ok, nil}

      {:ok, id} when is_binary(id) or is_nil(id) ->
        {:ok, id}

      {:ok, _other} ->
        error(:invalid_tool_call, "malformed #{path}.id: expected string or nil")
    end
  end

  defp decode_tool_name(function, path) do
    case fetch_known(function, "name") do
      :error ->
        error(:invalid_tool_call, "missing required field #{path}")

      {:ok, name} when is_binary(name) ->
        if String.trim(name) == "" do
          error(:invalid_tool_call, "malformed #{path}: expected non-empty string")
        else
          {:ok, name}
        end

      {:ok, _other} ->
        error(:invalid_tool_call, "malformed #{path}: expected non-empty string")
    end
  end

  defp decode_tool_arguments(function, path) do
    case fetch_known(function, "arguments") do
      :error -> decode_tool_arguments_value(nil, path)
      {:ok, arguments} -> decode_tool_arguments_value(arguments, path)
    end
  end

  defp decode_tool_arguments_value(arguments, _path) when is_map(arguments), do: {:ok, arguments}
  defp decode_tool_arguments_value(nil, _path), do: {:ok, %{}}

  defp decode_tool_arguments_value(arguments, path) when is_binary(arguments) do
    case String.trim(arguments) do
      "" ->
        {:ok, %{}}

      json ->
        decode_tool_arguments_json(json, path)
    end
  end

  defp decode_tool_arguments_value(_arguments, path) do
    error(:invalid_tool_call_arguments, "malformed #{path}: expected JSON string, map, or nil")
  end

  defp decode_tool_arguments_json(json, path) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        error(:invalid_tool_call_arguments, "malformed #{path}: expected JSON object")

      {:error, reason} ->
        message = reason |> Exception.message() |> redact_error_message()
        error(:invalid_tool_call_arguments, "invalid JSON at #{path}: #{message}")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp required_map(map, key, path, error_type \\ :invalid_response) do
    case fetch_known(map, key) do
      :error ->
        error(error_type, "missing required field #{path}")

      {:ok, value} when is_map(value) ->
        {:ok, value}

      {:ok, _other} ->
        error(error_type, "malformed #{path}: expected map")
    end
  end

  defp fetch_known(map, key) when is_map(map) and is_binary(key) do
    atom_key = Map.fetch!(@known_atom_keys, key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, atom_key) -> {:ok, Map.fetch!(map, atom_key)}
      true -> :error
    end
  end

  defp error(type, message) when is_atom(type) and is_binary(message) do
    {:error, {type, redact_error_message(message)}}
  end

  defp redact_error_message(message) do
    message
    |> EventPayloadRedactor.redact_string()
    |> String.slice(0, @max_error_message_length)
  end
end
