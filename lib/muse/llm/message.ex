defmodule Muse.LLM.Message do
  @moduledoc """
  Provider-neutral message struct for LLM requests.

  Normalized across all provider wire APIs (Responses, Chat Completions, etc.).
  The `role` field uses standard LLM protocol roles. Internal Muse product
  names (Planning Muse, Coding Muse, etc.) are not reflected here — this
  struct is an implementation detail, not a user-facing label.

  ## Fields

    * `role`          — `:system`, `:user`, `:assistant`, or `:tool`
    * `content`       — the message text (nil for assistant tool-call-only messages)
    * `name`          — optional participant name (used by some wire APIs)
    * `tool_call_id`  — required when `role` is `:tool`; links to a `ToolCall.id`
    * `metadata`      — optional map for provider-specific extensions

  ## Constructors

  Prefer `system/1`, `user/1`, `assistant/1`, and `tool/2` for readable
  construction. The struct can also be created directly.

      iex> msg = Muse.LLM.Message.user("add a /version command")
      iex> msg.role
      :user
      iex> msg.content
      "add a /version command"
  """

  @type role :: :system | :user | :assistant | :tool

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | nil,
          name: String.t() | nil,
          tool_call_id: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:role]
  defstruct [:role, :content, :name, :tool_call_id, metadata: %{}]

  @doc """
  Create a system message.
  """
  @spec system(String.t()) :: t()
  def system(content) when is_binary(content) do
    %__MODULE__{role: :system, content: content}
  end

  @doc """
  Create a user message.
  """
  @spec user(String.t()) :: t()
  def user(content) when is_binary(content) do
    %__MODULE__{role: :user, content: content}
  end

  @doc """
  Create an assistant message.

  `content` may be `nil` for tool-call-only assistant turns.
  """
  @spec assistant(String.t() | nil) :: t()
  def assistant(content) when is_binary(content) or is_nil(content) do
    %__MODULE__{role: :assistant, content: content}
  end

  @doc """
  Create a tool-result message.

  `tool_call_id` must match the `Muse.LLM.ToolCall.id` that produced this result.
  """
  @spec tool(String.t(), String.t()) :: t()
  def tool(content, tool_call_id) when is_binary(content) and is_binary(tool_call_id) do
    %__MODULE__{role: :tool, content: content, tool_call_id: tool_call_id}
  end
end
