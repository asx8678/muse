defmodule Muse.LLM.Response do
  @moduledoc """
  Provider-neutral response struct for LLM calls.

  Returned by `Muse.LLM.Provider.stream/2` and `Muse.LLM.Provider.complete/2`
  after all events have been emitted.  Contains the full assembled content,
  any tool calls the model requested, usage stats, and optional
  provider-specific state.

  ## Fields

    * `id`             — provider-assigned response identifier
    * `content`        — the assembled assistant text content
    * `text`           — alias for `content` (kept for backward compatibility)
    * `tool_calls`     — list of `Muse.LLM.ToolCall.t()` the model requested
    * `usage`          — token usage map (e.g. `%{prompt_tokens: 10, completion_tokens: 20}`)
    * `provider_state` — opaque map for provider-side conversation state
    * `finish_reason`  — why the model stopped (`"stop"`, `"tool_calls"`, etc.)
    * `raw`            — original provider-specific payload (for debugging)

  ## Constructor

      iex> resp = Muse.LLM.Response.new(content: "Hello", finish_reason: "stop")
      iex> resp.text
      "Hello"
  """

  alias Muse.LLM.ToolCall

  @type t :: %__MODULE__{
          id: String.t() | nil,
          content: String.t() | nil,
          text: String.t() | nil,
          tool_calls: [ToolCall.t()],
          usage: map() | nil,
          provider_state: map() | nil,
          finish_reason: String.t() | nil,
          raw: term() | nil
        }

  defstruct [:id, :content, :text, :tool_calls, :usage, :provider_state, :finish_reason, :raw]

  @doc """
  Create a response with the given keyword options.

  `:text` defaults to `:content` if not provided. `:tool_calls` defaults to `[]`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    content = Keyword.get(opts, :content)
    text = Keyword.get(opts, :text, content)

    %__MODULE__{
      id: Keyword.get(opts, :id),
      content: content,
      text: text,
      tool_calls: Keyword.get(opts, :tool_calls, []),
      usage: Keyword.get(opts, :usage),
      provider_state: Keyword.get(opts, :provider_state),
      finish_reason: Keyword.get(opts, :finish_reason),
      raw: Keyword.get(opts, :raw)
    }
  end

  @doc """
  Check whether the response contains any tool calls.
  """
  @spec has_tool_calls?(t()) :: boolean()
  def has_tool_calls?(%__MODULE__{tool_calls: calls}), do: calls != [] and not is_nil(calls)

  @doc """
  Check whether the response has assistant text content.
  """
  @spec has_content?(t()) :: boolean()
  def has_content?(%__MODULE__{content: nil, text: nil}), do: false
  def has_content?(%__MODULE__{content: "", text: ""}), do: false
  def has_content?(%__MODULE__{}), do: true
end
