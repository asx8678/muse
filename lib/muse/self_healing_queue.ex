defmodule Muse.SelfHealingQueue do
  @moduledoc """
  In-memory GenServer holding self-healing issues queued for the next
  Muse turn.

  Issues are deduplicated by `diagnostic_id` and bounded to a configurable
  maximum (default 100).  All mutations are broadcast on the
  `muse:self_healing` PubSub topic.
  """

  use GenServer

  alias Muse.SelfHealingIssue

  @topic "muse:self_healing"
  @default_max 100

  # -- Public API ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list() :: [SelfHealingIssue.t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @spec queued() :: [SelfHealingIssue.t()]
  def queued, do: GenServer.call(__MODULE__, :queued)

  @spec add_diagnostic(Muse.Diagnostic.t()) :: SelfHealingIssue.t() | {:error, :duplicate}
  def add_diagnostic(%Muse.Diagnostic{} = diagnostic) do
    GenServer.call(__MODULE__, {:add_diagnostic, diagnostic})
  end

  @spec add_issue(SelfHealingIssue.t()) :: SelfHealingIssue.t() | {:error, :duplicate}
  def add_issue(%SelfHealingIssue{} = issue) do
    GenServer.call(__MODULE__, {:add_issue, issue})
  end

  @spec remove(pos_integer()) :: :ok | {:error, :not_found}
  def remove(id), do: GenServer.call(__MODULE__, {:remove, id})

  @spec mark_in_progress(pos_integer()) :: SelfHealingIssue.t() | {:error, :not_found}
  def mark_in_progress(id), do: GenServer.call(__MODULE__, {:mark_in_progress, id})

  @spec mark_fixed(pos_integer()) :: SelfHealingIssue.t() | {:error, :not_found}
  def mark_fixed(id), do: GenServer.call(__MODULE__, {:mark_fixed, id})

  @spec mark_failed(pos_integer(), String.t()) :: SelfHealingIssue.t() | {:error, :not_found}
  def mark_failed(id, reason \\ ""), do: GenServer.call(__MODULE__, {:mark_failed, id, reason})

  @spec claim_queued() :: [SelfHealingIssue.t()]
  @doc """
  Atomically claims all queued issues, transitioning them to `:in_progress`.

  Finds all issues with `status == :queued`, transitions them to
  `:in_progress`, broadcasts an update for each, and returns the
  transitioned issues.  A second call returns `[]` since no issues
  remain queued.  This is safe against concurrent `submit/2` calls.
  """
  def claim_queued, do: GenServer.call(__MODULE__, :claim_queued)

  @spec clear_fixed() :: :ok
  def clear_fixed, do: GenServer.call(__MODULE__, :clear_fixed)

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    case Process.whereis(Muse.PubSub) do
      nil -> {:error, :pubsub_unavailable}
      _pid -> Phoenix.PubSub.subscribe(Muse.PubSub, @topic)
    end
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    max = opts |> Keyword.get(:max, @default_max) |> normalize_max()
    {:ok, %{issues: [], max: max}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.issues, state}
  end

  @impl true
  def handle_call(:queued, _from, state) do
    queued = Enum.filter(state.issues, &(&1.status == :queued))
    {:reply, queued, state}
  end

  @impl true
  def handle_call({:add_diagnostic, diagnostic}, _from, state) do
    if duplicate?(state.issues, diagnostic.id) do
      {:reply, {:error, :duplicate}, state}
    else
      issue = SelfHealingIssue.from_diagnostic(diagnostic)
      new_issues = [issue | state.issues] |> Enum.take(state.max)
      broadcast({:self_healing_issue_added, issue})
      {:reply, issue, %{state | issues: new_issues}}
    end
  end

  @impl true
  def handle_call({:add_issue, %SelfHealingIssue{} = issue}, _from, state) do
    if duplicate?(state.issues, issue.diagnostic_id) do
      {:reply, {:error, :duplicate}, state}
    else
      new_issues = [issue | state.issues] |> Enum.take(state.max)
      broadcast({:self_healing_issue_added, issue})
      {:reply, issue, %{state | issues: new_issues}}
    end
  end

  @impl true
  def handle_call({:remove, id}, _from, state) do
    case Enum.find(state.issues, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      issue ->
        new_issues = Enum.reject(state.issues, &(&1.id == id))
        broadcast({:self_healing_issue_removed, issue})
        {:reply, :ok, %{state | issues: new_issues}}
    end
  end

  @impl true
  def handle_call({:mark_in_progress, id}, _from, state) do
    case find_and_update(state.issues, id, &SelfHealingIssue.with_status(&1, :in_progress)) do
      {:ok, updated_issue, new_issues} ->
        broadcast({:self_healing_issue_updated, updated_issue})
        {:reply, updated_issue, %{state | issues: new_issues}}

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:mark_fixed, id}, _from, state) do
    case find_and_update(state.issues, id, &SelfHealingIssue.with_status(&1, :fixed)) do
      {:ok, updated_issue, new_issues} ->
        broadcast({:self_healing_issue_updated, updated_issue})
        {:reply, updated_issue, %{state | issues: new_issues}}

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:mark_failed, id, reason}, _from, state) do
    case find_and_update(state.issues, id, &SelfHealingIssue.with_failure(&1, reason)) do
      {:ok, updated_issue, new_issues} ->
        broadcast({:self_healing_issue_updated, updated_issue})
        {:reply, updated_issue, %{state | issues: new_issues}}

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:claim_queued, _from, state) do
    {new_issues, claimed_reversed} =
      Enum.reduce(state.issues, {[], []}, fn issue, {acc_issues, acc_claimed} ->
        if issue.status == :queued do
          updated = SelfHealingIssue.with_status(issue, :in_progress)
          broadcast({:self_healing_issue_updated, updated})
          {[updated | acc_issues], [updated | acc_claimed]}
        else
          {[issue | acc_issues], acc_claimed}
        end
      end)

    {:reply, Enum.reverse(claimed_reversed), %{state | issues: Enum.reverse(new_issues)}}
  end

  @impl true
  def handle_call(:clear_fixed, _from, state) do
    fixed = Enum.filter(state.issues, &(&1.status == :fixed))
    new_issues = Enum.reject(state.issues, &(&1.status == :fixed))

    if fixed != [] do
      broadcast({:self_healing_issues_cleared, fixed})
    end

    {:reply, :ok, %{state | issues: new_issues}}
  end

  # -- Private helpers ----------------------------------------------------------

  defp normalize_max(max) when is_integer(max) and max > 0, do: max
  defp normalize_max(_max), do: @default_max

  defp duplicate?(issues, diagnostic_id) do
    Enum.any?(issues, &(&1.diagnostic_id == diagnostic_id))
  end

  defp find_and_update(issues, id, update_fn) do
    case Enum.find_index(issues, &(&1.id == id)) do
      nil ->
        :not_found

      index ->
        found = Enum.at(issues, index)
        updated = update_fn.(found)
        new_issues = List.replace_at(issues, index, updated)
        {:ok, updated, new_issues}
    end
  end

  defp broadcast(message) do
    case Process.whereis(Muse.PubSub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(Muse.PubSub, @topic, message)
    end
  rescue
    e ->
      Muse.Diagnostics.SilentRescue.log_rescued(__MODULE__, :broadcast, e)
      :ok
  catch
    :exit, reason ->
      Muse.Diagnostics.SilentRescue.log_rescued_catch(__MODULE__, :broadcast, :exit, reason)
      :ok
  end
end
