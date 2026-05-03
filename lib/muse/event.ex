defmodule Muse.Event do
  @moduledoc """
  Immutable event record produced throughout the Muse system.

  Every event gets a unique monotonically-increasing integer ID and a UTC
  timestamp at creation time.  `source`, `type`, and `data` are caller-defined.

  ## Metadata fields

  The extended fields (`session_id`, `turn_id`, `seq`, `parent_id`, `visibility`,
  `muse_id`) provide structured context for session-aware event routing,
  replay, and filtering.  They are all optional — `Event.new/3` continues
  to work exactly as before, setting metadata fields to `nil`.

  `Event.new/4` accepts a keyword list of metadata overrides.  For
  deterministic testing, pass `id:` and `timestamp:` in the keyword list
  to pin those values.

  ## Visibility

  | Value        | Meaning |
  |--------------|---------|
  | `:user`      | Safe to show in CLI/TUI/LiveView chat |
  | `:debug`     | Safe for event/debug log only |
  | `:internal`  | Persisted but not normally shown |
  | `:sensitive` | Should not be stored unless redacted first |
  """

  @enforce_keys [:id, :timestamp, :source, :type, :data]
  defstruct [
    :id,
    :timestamp,
    :source,
    :type,
    :data,
    :session_id,
    :turn_id,
    :seq,
    :parent_id,
    :visibility,
    :muse_id
  ]

  @type visibility :: :user | :debug | :internal | :sensitive

  @type t :: %__MODULE__{
          id: pos_integer(),
          timestamp: DateTime.t(),
          source: atom(),
          type: atom(),
          data: term(),
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          seq: non_neg_integer() | nil,
          parent_id: pos_integer() | nil,
          visibility: visibility() | nil,
          muse_id: String.t() | nil
        }

  @doc """
  Create an event with the core fields only (backward compatible).

  All metadata fields default to `nil`.

      iex> event = Muse.Event.new(:cli, :started, %{repl: true})
      iex> event.source
      :cli
      iex> event.session_id
      nil
  """
  @spec new(atom(), atom(), term()) :: t()
  def new(source, type, data) do
    new(source, type, data, [])
  end

  @doc """
  Create an event with core fields plus optional metadata.

  Accepted keyword options:

    * `:id`         — override the auto-generated ID (for deterministic tests)
    * `:timestamp`  — override the UTC timestamp (for deterministic tests)
    * `:session_id` — session this event belongs to
    * `:turn_id`     — turn this event belongs to
    * `:seq`         — session-local monotonic sequence number
    * `:parent_id`   — ID of the parent event (for causality chains)
    * `:visibility`  — `:user` | `:debug` | `:internal` | `:sensitive`
    * `:muse_id`     — the Muse profile that produced this event

      iex> event = Muse.Event.new(:planning_muse, :assistant_delta, %{text: "..."},
      ...>   session_id: "sess_1", seq: 5, visibility: :user)
      iex> event.session_id
      "sess_1"
      iex> event.seq
      5
  """
  @spec new(atom(), atom(), term(), keyword()) :: t()
  def new(source, type, data, opts) when is_list(opts) do
    %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      source: source,
      type: type,
      data: data,
      session_id: Keyword.get(opts, :session_id),
      turn_id: Keyword.get(opts, :turn_id),
      seq: Keyword.get(opts, :seq),
      parent_id: Keyword.get(opts, :parent_id),
      visibility: Keyword.get(opts, :visibility),
      muse_id: Keyword.get(opts, :muse_id)
    }
  end

  @doc """
  Return the list of valid visibility values.

      iex> Muse.Event.visibilities()
      [:user, :debug, :internal, :sensitive]
  """
  @spec visibilities() :: [visibility()]
  def visibilities, do: [:user, :debug, :internal, :sensitive]

  @doc """
  Check whether the given visibility value is valid.
  """
  @spec valid_visibility?(term()) :: boolean()
  def valid_visibility?(v), do: v in visibilities()

  defp generate_id, do: System.unique_integer([:positive])
end
