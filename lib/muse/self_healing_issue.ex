defmodule Muse.SelfHealingIssue do
  @moduledoc """
  Immutable record representing a diagnostic queued for self-healing.

  Each issue tracks a diagnostic that a user flagged for the next
  agent/development turn.  Messages are safely stringified and
  truncated.  Map metadata is preserved as-is (matching
  `Muse.Diagnostic` style); non-map metadata is safely inspected
  and wrapped.
  """

  @enforce_keys [:id, :diagnostic_id, :created_at, :updated_at, :status, :level, :message]
  defstruct [
    :id,
    :diagnostic_id,
    :created_at,
    :updated_at,
    :status,
    :level,
    :message,
    :metadata,
    :source,
    :failure_reason
  ]

  @type status :: :queued | :in_progress | :fixed | :failed | :ignored

  @type t :: %__MODULE__{
          id: pos_integer(),
          diagnostic_id: pos_integer(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          status: status(),
          level: atom(),
          message: String.t(),
          metadata: map() | nil,
          source: atom() | String.t() | nil,
          failure_reason: String.t() | nil
        }

  @max_message_chars 2_000
  @max_metadata_chars 2_000
  @inspect_limit 50

  @valid_statuses [:queued, :in_progress, :fixed, :failed, :ignored]

  @doc """
  Builds a new self-healing issue from an existing `Muse.Diagnostic`.

  The issue starts with status `:queued`.  Messages are defensively
  stringified and truncated.  Map metadata is preserved as-is;
  non-map metadata is safely inspected and wrapped.
  """
  @spec from_diagnostic(Muse.Diagnostic.t()) :: t()
  def from_diagnostic(%Muse.Diagnostic{} = diagnostic) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      diagnostic_id: diagnostic.id,
      created_at: now,
      updated_at: now,
      status: :queued,
      level: diagnostic.level,
      message: diagnostic.message |> safe_to_string() |> truncate(@max_message_chars),
      metadata: normalize_metadata(diagnostic.metadata),
      source: extract_source(diagnostic.metadata)
    }
  end

  @doc """
  Marks an issue with a new status, updating `updated_at`.
  """
  @spec with_status(t(), status()) :: t()
  def with_status(%__MODULE__{} = issue, status) when status in @valid_statuses do
    %{issue | status: status, updated_at: DateTime.utc_now()}
  end

  def with_status(%__MODULE__{}, status) do
    raise ArgumentError,
          "unsupported self-healing issue status #{inspect(status)}; expected one of #{inspect(@valid_statuses)}"
  end

  @doc """
  Marks an issue as failed with an optional reason.
  """
  @spec with_failure(t(), String.t()) :: t()
  def with_failure(%__MODULE__{} = issue, reason) do
    %{issue | status: :failed, updated_at: DateTime.utc_now(), failure_reason: reason}
  end

  # -- Private helpers ----------------------------------------------------------

  defp extract_source(metadata) when is_map(metadata) do
    Map.get(metadata, :source) || Map.get(metadata, "source")
  end

  defp extract_source(_metadata), do: nil

  defp safe_to_string(term) when is_binary(term), do: term

  defp safe_to_string(term) do
    try do
      to_string(term)
    rescue
      _ -> safe_inspect(term)
    catch
      _, _ -> safe_inspect(term)
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata

  defp normalize_metadata(metadata) do
    %{metadata: metadata |> safe_inspect() |> truncate(@max_metadata_chars)}
  end

  defp safe_inspect(term) do
    inspect(term, limit: @inspect_limit, printable_limit: @max_metadata_chars)
  rescue
    _ -> "#Inspect.Error<uninspectable>"
  catch
    _, _ -> "#Inspect.Error<uninspectable>"
  end

  defp truncate(string, max_chars) do
    if String.length(string) > max_chars do
      String.slice(string, 0, max_chars)
    else
      string
    end
  end

  defp generate_id, do: System.unique_integer([:positive])
end
