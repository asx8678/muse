defmodule Muse.Turn do
  @moduledoc """
  Struct representing a single conversational turn within a session.

  A turn captures the user's input, the selected Muse, the model/tool loop
  execution state, and the accumulated result. Turns are created by the
  Conductor and owned by the SessionServer.

  ## Status lifecycle

      :queued → :running → :awaiting_approval → :completed | :failed | :cancelled

  `Muse.Turn.statuses/0` returns the canonical list.

  ## The `streamed?` flag

  When `streamed?` is `true`, assistant deltas have already been rendered
  to the terminal during the streaming phase.  On turn completion, the CLI
  suppresses the full-message reprint to avoid duplicating output the user
  has already seen.

  ## Construction

      iex> turn = Muse.Turn.new(session_id: "sess_1", source: :user, user_text: "hello")
      iex> turn.status
      :queued

  For deterministic tests, pass `id:` and `started_at:`:

      iex> turn = Muse.Turn.new(session_id: "sess_1", source: :user, user_text: "hi", id: "turn_1")
      iex> turn.id
      "turn_1"
  """

  @enforce_keys [:id, :session_id, :source, :status, :started_at]
  defstruct [
    :id,
    :session_id,
    :source,
    :user_text,
    :selected_muse,
    :status,
    :started_at,
    :completed_at,
    assistant_buffer: "",
    tool_calls: [],
    result: nil,
    streamed?: false
  ]

  @type status ::
          :queued
          | :running
          | :awaiting_approval
          | :completed
          | :failed
          | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          source: atom(),
          user_text: String.t() | nil,
          selected_muse: String.t() | nil,
          status: status(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          assistant_buffer: String.t(),
          tool_calls: list(),
          result: term() | nil,
          streamed?: boolean()
        }

  @doc """
  Return the canonical list of turn statuses.

      iex> Muse.Turn.statuses()
      [:queued, :running, :awaiting_approval, :completed, :failed, :cancelled]
  """
  @spec statuses() :: [status()]
  def statuses do
    [:queued, :running, :awaiting_approval, :completed, :failed, :cancelled]
  end

  @doc """
  Check whether the given status is valid.
  """
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in statuses()

  @doc """
  Create a new turn struct in `:queued` status.

  ## Options

    * `:id`            — turn identifier (defaults to a generated ID)
    * `:source`        — the origin of the turn (default `:user`)
    * `:user_text`     — the user's input text
    * `:selected_muse` — the Muse profile chosen for this turn
    * `:started_at`    — override timestamp (for deterministic tests)

  All other struct fields default to their zero values.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      session_id: Keyword.fetch!(opts, :session_id),
      source: Keyword.get(opts, :source, :user),
      user_text: Keyword.get(opts, :user_text),
      selected_muse: Keyword.get(opts, :selected_muse),
      status: :queued,
      started_at: Keyword.get(opts, :started_at, now)
    }
  end

  @doc """
  Transition a turn to a new status.

  Returns `{:ok, turn}` when the status is valid, or
  `{:error, {:invalid_status, status}}` when it is not.

  When transitioning to `:completed` or `:failed`, the `completed_at`
  field is set automatically unless overridden via the `:completed_at`
  option. The `started_at` field can also be overridden via `:started_at`
  for deterministic tests.
  """
  @spec transition(t(), status(), keyword()) :: {:ok, t()} | {:error, {:invalid_status, term()}}
  def transition(%__MODULE__{} = turn, new_status, opts \\ []) do
    if valid_status?(new_status) do
      now = DateTime.utc_now()

      completed_at =
        if new_status in [:completed, :failed, :cancelled] do
          Keyword.get(opts, :completed_at, now)
        else
          turn.completed_at
        end

      {:ok,
       %{
         turn
         | status: new_status,
           completed_at: completed_at,
           started_at: Keyword.get(opts, :started_at, turn.started_at)
       }}
    else
      {:error, {:invalid_status, new_status}}
    end
  end

  @doc """
  Mark the turn as streamed.

  Sets `streamed?` to `true`, indicating that deltas have already been
  rendered to the terminal during streaming.
  """
  @spec mark_streamed(t()) :: t()
  def mark_streamed(%__MODULE__{} = turn) do
    %{turn | streamed?: true}
  end

  defp generate_id do
    hex =
      :crypto.strong_rand_bytes(8)
      |> Base.encode16(case: :lower)

    "turn_#{hex}"
  end
end
