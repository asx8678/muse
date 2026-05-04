defmodule Muse.LLM.Request do
  @moduledoc """
  Provider-neutral request struct for LLM calls.

  Built by `Muse.Prompt.ModelPreparer` from a prompt bundle and passed to
  `Muse.LLM.Provider.stream/2` or `Muse.LLM.Provider.complete/2`.  Each
  provider adapter reads the fields it needs and ignores the rest.

  ## Fields

    * `provider`             — atom identifying the target provider (`:fake`, etc.)
    * `model`                — model identifier (e.g. `"gpt-4.1"`, `"fake-planning-model"`)
    * `wire_api`             — `:responses` | `:chat_completions` | `nil`
    * `transport`            — `:none` | `:sse` | `:websocket` | `nil`
    * `session_id`           — the Muse session this request belongs to
    * `turn_id`              — the turn identifier within the session
    * `messages`             — list of `Muse.LLM.Message.t()` in conversation order
    * `prompt_bundle`        — the assembled prompt bundle (for debugging/preview)
    * `tools`                — list of tool spec maps available for this turn
    * `tool_choice`          — `:auto` | `:none` | `:required` | `{:function, name}` | `nil`
    * `previous_response_id` — OpenAI Responses API conversation continuity
    * `stream`               — whether to request streaming (default `true`)
    * `store`                — whether the provider should persist the response
    * `temperature`          — sampling temperature override
    * `max_tokens`           — maximum output tokens
    * `response_format`      — structured output format map
    * `metadata`             — optional provider-specific metadata
    * `options`              — extensible map for provider-specific options

  ## Scripting the Fake Provider

  The `options` map supports fake-provider scripting keys:

    * `:fake_events` — list of script entries or `Muse.LLM.Event` structs
    * `:fake_error`  — atom or term to simulate a provider error

  These keys are **ignored** by real providers.
  """

  alias Muse.LLM.Message

  @type wire_api :: :responses | :chat_completions | nil
  @type transport :: :none | :sse | :websocket | nil
  @type tool_choice :: :auto | :none | :required | {:function, String.t()} | nil

  @type t :: %__MODULE__{
          provider: atom() | nil,
          model: String.t() | nil,
          wire_api: wire_api(),
          transport: transport(),
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          messages: [Message.t()],
          prompt_bundle: term() | nil,
          tools: [map()] | nil,
          tool_choice: tool_choice(),
          previous_response_id: String.t() | nil,
          stream: boolean(),
          store: boolean() | nil,
          temperature: float() | nil,
          max_tokens: non_neg_integer() | nil,
          response_format: map() | nil,
          metadata: map() | nil,
          options: map()
        }

  defstruct [
    :provider,
    :model,
    :wire_api,
    :transport,
    :session_id,
    :turn_id,
    :messages,
    :prompt_bundle,
    :tools,
    :tool_choice,
    :previous_response_id,
    :store,
    :temperature,
    :max_tokens,
    :response_format,
    :metadata,
    stream: true,
    options: %{}
  ]

  @doc """
  Extract the latest user message text from the request.

  Returns `"(no user message)"` if no user messages are present.
  Used by the fake provider to generate deterministic default responses.
  """
  @spec latest_user_text(t()) :: String.t()
  def latest_user_text(%__MODULE__{messages: nil}), do: "(no user message)"

  def latest_user_text(%__MODULE__{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
    |> case do
      nil -> "(no user message)"
      %{content: content} when is_binary(content) -> content
      _ -> "(no user message)"
    end
  end
end
