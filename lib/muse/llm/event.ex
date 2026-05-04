defmodule Muse.LLM.Event do
  @moduledoc """
  Normalized LLM event struct emitted by providers during streaming.

  Every provider adapter — fake, OpenAI, OpenRouter, Ollama — normalizes its
  wire-specific events into this struct before passing them to the emit
  callback.  The runtime and UI layers only see these canonical types.

  ## Event Types

  | Type                  | Meaning                                      |
  |-----------------------|----------------------------------------------|
  | `:response_started`   | Provider has begun streaming a response      |
  | `:assistant_delta`    | Partial text chunk from the assistant         |
  | `:assistant_completed`| Full assistant text is complete               |
  | `:tool_call_started`  | A tool call has been initiated by the model   |
  | `:tool_call_delta`    | Partial tool-call argument text               |
  | `:tool_call_completed`| A tool call is fully specified                |
  | `:response_completed` | The provider response is fully done           |
  | `:provider_error`     | The provider returned an error                |

  ## Fields

    * `type`       — one of the event types above
    * `text`       — text content for `:assistant_delta` / `:assistant_completed`
    * `tool_call`  — `Muse.LLM.ToolCall.t()` or partial map for tool-call events
    * `raw`        — original provider-specific payload (debugging)
    * `usage`      — token usage map (typically on `:response_completed`)
    * `error`       — error detail for `:provider_error`

  ## Constructors

  Prefer the named constructors over direct struct creation for readability:

      iex> Muse.LLM.Event.assistant_delta("Hello")
      %Muse.LLM.Event{type: :assistant_delta, text: "Hello"}
  """

  alias Muse.LLM.ToolCall

  @type event_type ::
          :response_started
          | :assistant_delta
          | :assistant_completed
          | :tool_call_started
          | :tool_call_delta
          | :tool_call_completed
          | :response_completed
          | :provider_error

  @type t :: %__MODULE__{
          type: event_type(),
          text: String.t() | nil,
          tool_call: ToolCall.t() | map() | nil,
          raw: term() | nil,
          usage: map() | nil,
          error: term() | nil
        }

  @enforce_keys [:type]
  defstruct [:type, :text, :tool_call, :raw, :usage, :error]

  @doc """
  List all valid event types.
  """
  @spec event_types() :: [event_type()]
  def event_types do
    [
      :response_started,
      :assistant_delta,
      :assistant_completed,
      :tool_call_started,
      :tool_call_delta,
      :tool_call_completed,
      :response_completed,
      :provider_error
    ]
  end

  @doc """
  Check whether the given term is a valid event type.
  """
  @spec valid_event_type?(term()) :: boolean()
  def valid_event_type?(type), do: type in event_types()

  @doc """
  Create a `:response_started` event.
  """
  @spec response_started() :: t()
  def response_started, do: %__MODULE__{type: :response_started}

  @doc """
  Create an `:assistant_delta` event with incremental text.
  """
  @spec assistant_delta(String.t()) :: t()
  def assistant_delta(text) when is_binary(text),
    do: %__MODULE__{type: :assistant_delta, text: text}

  @doc """
  Create an `:assistant_completed` event.

  Optionally includes the full assembled text.
  """
  @spec assistant_completed(String.t() | nil) :: t()
  def assistant_completed(text \\ nil), do: %__MODULE__{type: :assistant_completed, text: text}

  @doc """
  Create a `:tool_call_started` event.
  """
  @spec tool_call_started(ToolCall.t() | map()) :: t()
  def tool_call_started(tool_call),
    do: %__MODULE__{type: :tool_call_started, tool_call: tool_call}

  @doc """
  Create a `:tool_call_delta` event with partial tool-call data.
  """
  @spec tool_call_delta(ToolCall.t() | map()) :: t()
  def tool_call_delta(tool_call), do: %__MODULE__{type: :tool_call_delta, tool_call: tool_call}

  @doc """
  Create a `:tool_call_completed` event.
  """
  @spec tool_call_completed(ToolCall.t() | map()) :: t()
  def tool_call_completed(tool_call),
    do: %__MODULE__{type: :tool_call_completed, tool_call: tool_call}

  @doc """
  Create a `:response_completed` event.

  Optionally includes token usage data.
  """
  @spec response_completed(map() | nil) :: t()
  def response_completed(usage \\ nil), do: %__MODULE__{type: :response_completed, usage: usage}

  @doc """
  Create a `:provider_error` event.

  The `error` term will be redacted before emission to the event system
  if it contains secrets. Callers should pre-redact sensitive data.
  """
  @spec provider_error(term()) :: t()
  def provider_error(error), do: %__MODULE__{type: :provider_error, error: error}
end
