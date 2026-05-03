defmodule Muse.Telemetry do
  @moduledoc """
  Canonical telemetry event definitions and metadata helpers for the Muse system.

  All telemetry events use `:telemetry.execute/3` with the event names,
  measurements, and metadata defined here.  This module provides:

    * Named constants for every telemetry event name
    * Helper functions to build measurement and metadata maps
    * Validation that metadata never includes secrets or provider credentials

  Handler attachment happens in `Muse.Application`; this module does **not**
  wire any handlers.

  ## Usage

      :telemetry.execute(
        Muse.Telemetry.turn_start(),
        Muse.Telemetry.turn_start_measurements(),
        Muse.Telemetry.turn_start_metadata(session_id: "sess_1", turn_id: "turn_1")
      )

  ## Safety

  Metadata helpers scrub secrets using `Muse.MetadataSanitizer`.  Never
  include API keys, tokens, or provider credentials in telemetry metadata.
  """

  alias Muse.MetadataSanitizer

  # -- Turn events --------------------------------------------------------------

  @doc "Event name: `[:muse, :turn, :start]`"
  @spec turn_start() :: :telemetry.event_name()
  def turn_start, do: [:muse, :turn, :start]

  @doc "Event name: `[:muse, :turn, :stop]`"
  @spec turn_stop() :: :telemetry.event_name()
  def turn_stop, do: [:muse, :turn, :stop]

  @doc "Event name: `[:muse, :turn, :exception]`"
  @spec turn_exception() :: :telemetry.event_name()
  def turn_exception, do: [:muse, :turn, :exception]

  @doc "Measurements for `[:muse, :turn, :stop]`."
  @spec turn_stop_measurements(duration_ms :: non_neg_integer()) :: :telemetry.measurements()
  def turn_stop_measurements(duration_ms) when is_integer(duration_ms) and duration_ms >= 0 do
    %{duration_ms: duration_ms}
  end

  @doc """
  Metadata for `[:muse, :turn, :start]`.

  Accepts `session_id`, `turn_id`, and `muse_id`.  The result is sanitized
  to ensure no secrets leak into telemetry.
  """
  @spec turn_start_metadata(keyword()) :: :telemetry.metadata()
  def turn_start_metadata(opts) when is_list(opts) do
    %{session_id: opts[:session_id], turn_id: opts[:turn_id], muse_id: opts[:muse_id]}
    |> sanitize_metadata()
  end

  @doc """
  Metadata for `[:muse, :turn, :stop]`.

  Accepts `session_id`, `turn_id`, and `status`.  Sanitized before return.
  """
  @spec turn_stop_metadata(keyword()) :: :telemetry.metadata()
  def turn_stop_metadata(opts) when is_list(opts) do
    %{session_id: opts[:session_id], turn_id: opts[:turn_id], status: opts[:status]}
    |> sanitize_metadata()
  end

  @doc """
  Metadata for `[:muse, :turn, :exception]`.

  Accepts `session_id`, `turn_id`, `kind`, `reason`, and `stacktrace`.
  Sanitized before return.
  """
  @spec turn_exception_metadata(keyword()) :: :telemetry.metadata()
  def turn_exception_metadata(opts) when is_list(opts) do
    %{
      session_id: opts[:session_id],
      turn_id: opts[:turn_id],
      kind: opts[:kind],
      reason: opts[:reason],
      stacktrace: opts[:stacktrace]
    }
    |> sanitize_metadata()
  end

  # -- Tool events --------------------------------------------------------------

  @doc "Event name: `[:muse, :tool, :start]`"
  @spec tool_start() :: :telemetry.event_name()
  def tool_start, do: [:muse, :tool, :start]

  @doc "Event name: `[:muse, :tool, :stop]`"
  @spec tool_stop() :: :telemetry.event_name()
  def tool_stop, do: [:muse, :tool, :stop]

  @doc "Event name: `[:muse, :tool, :exception]`"
  @spec tool_exception() :: :telemetry.event_name()
  def tool_exception, do: [:muse, :tool, :exception]

  @doc "Measurements for `[:muse, :tool, :stop]`."
  @spec tool_stop_measurements(duration_ms :: non_neg_integer()) :: :telemetry.measurements()
  def tool_stop_measurements(duration_ms) when is_integer(duration_ms) and duration_ms >= 0 do
    %{duration_ms: duration_ms}
  end

  @doc """
  Metadata for `[:muse, :tool, :start]` and `[:muse, :tool, :stop]`.

  Accepts `session_id`, `turn_id`, and `tool_name`.  Sanitized before return.
  """
  @spec tool_metadata(keyword()) :: :telemetry.metadata()
  def tool_metadata(opts) when is_list(opts) do
    %{session_id: opts[:session_id], turn_id: opts[:turn_id], tool_name: opts[:tool_name]}
    |> sanitize_metadata()
  end

  @doc """
  Metadata for `[:muse, :tool, :exception]`.

  Accepts `session_id`, `turn_id`, `tool_name`, and `reason`.  Sanitized before return.
  """
  @spec tool_exception_metadata(keyword()) :: :telemetry.metadata()
  def tool_exception_metadata(opts) when is_list(opts) do
    %{
      session_id: opts[:session_id],
      turn_id: opts[:turn_id],
      tool_name: opts[:tool_name],
      reason: opts[:reason]
    }
    |> sanitize_metadata()
  end

  # -- Provider events ----------------------------------------------------------

  @doc "Event name: `[:muse, :provider, :start]`"
  @spec provider_start() :: :telemetry.event_name()
  def provider_start, do: [:muse, :provider, :start]

  @doc "Event name: `[:muse, :provider, :stop]`"
  @spec provider_stop() :: :telemetry.event_name()
  def provider_stop, do: [:muse, :provider, :stop]

  @doc "Event name: `[:muse, :provider, :error]`"
  @spec provider_error() :: :telemetry.event_name()
  def provider_error, do: [:muse, :provider, :error]

  @doc "Measurements for `[:muse, :provider, :stop]`."
  @spec provider_stop_measurements(duration_ms :: non_neg_integer(), tokens :: map()) ::
          :telemetry.measurements()
  def provider_stop_measurements(duration_ms, tokens \\ %{})
      when is_integer(duration_ms) and duration_ms >= 0 and is_map(tokens) do
    Map.merge(%{duration_ms: duration_ms}, sanitize_metadata(tokens))
  end

  @doc """
  Metadata for `[:muse, :provider, :start]`.

  Accepts `session_id`, `turn_id`, `provider`, and `model`.  Provider
  credentials (API keys, tokens) are **never** included.  Sanitized before return.
  """
  @spec provider_start_metadata(keyword()) :: :telemetry.metadata()
  def provider_start_metadata(opts) when is_list(opts) do
    %{
      session_id: opts[:session_id],
      turn_id: opts[:turn_id],
      provider: opts[:provider],
      model: opts[:model]
    }
    |> sanitize_metadata()
  end

  @doc """
  Metadata for `[:muse, :provider, :stop]`.

  Accepts `session_id`, `turn_id`, and `usage`.  The `usage` key carries
  token counts safely — it is not a sensitive key name.  Avoid `tokens`
  as a key name because the MetadataSanitizer will redact it (it
  contains the word "token").  Sanitized before return.
  """
  @spec provider_stop_metadata(keyword()) :: :telemetry.metadata()
  def provider_stop_metadata(opts) when is_list(opts) do
    %{session_id: opts[:session_id], turn_id: opts[:turn_id], usage: opts[:usage]}
    |> sanitize_metadata()
  end

  @doc """
  Metadata for `[:muse, :provider, :error]`.

  Accepts `session_id`, `turn_id`, and `error_type`.  Sanitized before return.
  """
  @spec provider_error_metadata(keyword()) :: :telemetry.metadata()
  def provider_error_metadata(opts) when is_list(opts) do
    %{session_id: opts[:session_id], turn_id: opts[:turn_id], error_type: opts[:error_type]}
    |> sanitize_metadata()
  end

  # -- Session events -----------------------------------------------------------

  @doc "Event name: `[:muse, :session, :created]`"
  @spec session_created() :: :telemetry.event_name()
  def session_created, do: [:muse, :session, :created]

  @doc "Event name: `[:muse, :session, :loaded]`"
  @spec session_loaded() :: :telemetry.event_name()
  def session_loaded, do: [:muse, :session, :loaded]

  @doc """
  Metadata for `[:muse, :session, :created]`.

  Accepts `session_id` and `workspace`.  Sanitized before return.
  """
  @spec session_created_metadata(keyword()) :: :telemetry.metadata()
  def session_created_metadata(opts) when is_list(opts) do
    %{session_id: opts[:session_id], workspace: opts[:workspace]}
    |> sanitize_metadata()
  end

  @doc """
  Metadata for `[:muse, :session, :loaded]`.

  Accepts `session_id`.  Sanitized before return.
  """
  @spec session_loaded_metadata(keyword()) :: :telemetry.metadata()
  def session_loaded_metadata(opts) when is_list(opts) do
    %{session_id: opts[:session_id]}
    |> sanitize_metadata()
  end

  # -- Approval events ----------------------------------------------------------

  @doc "Event name: `[:muse, :approval, :granted]`"
  @spec approval_granted() :: :telemetry.event_name()
  def approval_granted, do: [:muse, :approval, :granted]

  @doc "Event name: `[:muse, :approval, :rejected]`"
  @spec approval_rejected() :: :telemetry.event_name()
  def approval_rejected, do: [:muse, :approval, :rejected]

  @doc """
  Metadata for approval events (`:granted` or `:rejected`).

  Accepts `session_id`, `kind`, and `id`.  Sanitized before return.
  """
  @spec approval_metadata(keyword()) :: :telemetry.metadata()
  def approval_metadata(opts) when is_list(opts) do
    %{session_id: opts[:session_id], kind: opts[:kind], id: opts[:id]}
    |> sanitize_metadata()
  end

  # -- All event names ----------------------------------------------------------

  @doc """
  Returns the list of all canonical telemetry event names.
  """
  @spec all_event_names() :: [:telemetry.event_name()]
  def all_event_names do
    [
      turn_start(),
      turn_stop(),
      turn_exception(),
      tool_start(),
      tool_stop(),
      tool_exception(),
      provider_start(),
      provider_stop(),
      provider_error(),
      session_created(),
      session_loaded(),
      approval_granted(),
      approval_rejected()
    ]
  end

  # -- Internal -----------------------------------------------------------------

  defp sanitize_metadata(metadata) when is_map(metadata) do
    MetadataSanitizer.sanitize(metadata)
  end
end
