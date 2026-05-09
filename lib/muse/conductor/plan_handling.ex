defmodule Muse.Conductor.PlanHandling do
  @moduledoc """
  Plan creation, identity, sanitization, versioning, and storage for the Conductor.

  When the Planning Muse produces a structured plan, this module handles:
  - Parsing the LLM output into a `%Plan{}`
  - Sanitizing provider-injected control fields
  - Assigning plan identity (ID, version)
  - Storing the plan in the session

  ## Lifecycle

  Called from `Muse.Conductor.execute_turn/4` when the Planning Muse
  completes a turn. Plans flow through `maybe_add_plan_to_result/5`
  which delegates to `finalize_as_plan/6` here for identity and storage.

  All functions are pure — they accept and return data structures
  with no side effects beyond plan construction.
  """

  alias Muse.{Plan, PlanParser, Session, Turn}

  @provider_metadata_control_keys MapSet.new([
                                    "approval",
                                    "approval_record",
                                    "approval_audit",
                                    "approvals",
                                    "active_approval",
                                    "approval_binding",
                                    "approval_request",
                                    "rejection",
                                    "rejection_record",
                                    "rejection_audit",
                                    "rejections"
                                  ])

  @doc """
  Attempt to parse plan output from assistant text.

  Delegates to `PlanParser.parse/2` with `extract: :auto`.
  """
  @spec parse_plan_output(String.t()) :: {:ok, Plan.t()} | {:error, term()}
  def parse_plan_output(text) do
    PlanParser.parse(text, extract: :auto)
  end

  @doc """
  Check if text looks like it is trying to be structured plan JSON.

  A generic JSON object (e.g. `{"status": "ok"}`) is not enough:
  repair should only run when the output carries plan-specific markers.
  """
  @spec looks_like_plan_json?(String.t() | term()) :: boolean()
  def looks_like_plan_json?(text) when is_binary(text) do
    String.contains?(text, "\"objective\"") or
      String.contains?(text, "\"tasks\"") or
      String.contains?(text, "'objective'") or
      String.contains?(text, "'tasks'")
  end

  def looks_like_plan_json?(_), do: false

  @doc """
  Prepare a plan's identity fields for storage.

  Sanitizes provider control fields, assigns a version and ID.
  """
  @spec prepare_plan_identity(Plan.t(), Session.t(), Turn.t(), map()) :: Plan.t()
  def prepare_plan_identity(%Plan{} = plan, %Session{} = session, %Turn{} = turn, muse) do
    plan
    |> sanitize_provider_plan_control_fields(session, muse)
    |> put_plan_version(session)
    |> put_plan_id(turn)
  end

  @doc """
  Sanitize provider-injected control fields from a plan.

  Resets approval/rejection state and strips control keys from metadata.
  """
  @spec sanitize_provider_plan_control_fields(Plan.t(), Session.t(), map()) :: Plan.t()
  def sanitize_provider_plan_control_fields(%Plan{} = plan, %Session{id: session_id}, muse) do
    %{
      plan
      | session_id: session_id,
        version: nil,
        created_by: muse_id(muse),
        approved_at: nil,
        rejected_at: nil,
        completed_at: nil,
        approvals: [],
        metadata: sanitize_provider_plan_metadata(plan.metadata)
    }
  end

  @doc """
  Store a plan in the session's plans map and set it as the active plan.
  """
  @spec store_plan_in_session(Session.t(), Plan.t()) :: Session.t()
  def store_plan_in_session(%Session{} = session, %Plan{} = plan) do
    plans = Map.put(session.plans || %{}, plan.id, plan)
    %{session | active_plan_id: plan.id, plans: plans}
  end

  @doc "Extract a muse ID string from a muse struct."
  @spec muse_id(map()) :: String.t() | nil
  def muse_id(%{id: muse_id}) when is_atom(muse_id), do: Atom.to_string(muse_id)
  def muse_id(%{id: muse_id}) when is_binary(muse_id), do: muse_id
  def muse_id(_muse), do: nil

  # -- Private helpers ----------------------------------------------------------

  defp sanitize_provider_plan_metadata(metadata) when is_map(metadata) do
    Map.reject(metadata, fn {key, _value} ->
      key
      |> normalize_provider_metadata_key()
      |> then(&MapSet.member?(@provider_metadata_control_keys, &1))
    end)
  end

  defp sanitize_provider_plan_metadata(_metadata), do: %{}

  defp normalize_provider_metadata_key(key) when is_atom(key),
    do: normalize_provider_metadata_key(Atom.to_string(key))

  defp normalize_provider_metadata_key(key) when is_binary(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize_provider_metadata_key(key),
    do: key |> inspect() |> normalize_provider_metadata_key()

  defp put_plan_version(%Plan{} = plan, %Session{} = session) do
    %{plan | version: next_plan_version(session)}
  end

  defp next_plan_version(%Session{plans: plans}) when is_map(plans) and map_size(plans) > 0 do
    plans
    |> Map.values()
    |> Enum.map(&plan_version/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp next_plan_version(_session), do: 1

  defp plan_version(%Plan{version: version}) when is_integer(version), do: version
  defp plan_version(_plan), do: 0

  defp put_plan_id(%Plan{} = plan, %Turn{id: turn_id}) do
    put_plan_field_if_blank(plan, :id, generated_plan_id(turn_id))
  end

  defp put_plan_field_if_blank(plan, field, value) do
    if blank_plan_field?(Map.get(plan, field)) do
      Map.put(plan, field, value)
    else
      plan
    end
  end

  defp blank_plan_field?(nil), do: true
  defp blank_plan_field?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_plan_field?(_value), do: false

  defp generated_plan_id(turn_id) when is_binary(turn_id) do
    case sanitize_plan_id_part(turn_id) do
      "" -> random_plan_id()
      sanitized -> "plan_" <> sanitized
    end
  end

  defp generated_plan_id(_turn_id), do: random_plan_id()

  defp random_plan_id do
    suffix =
      :crypto.strong_rand_bytes(8)
      |> Base.encode16(case: :lower)

    "plan_#{suffix}"
  end

  defp sanitize_plan_id_part(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
  end
end
