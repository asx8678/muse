defmodule Muse.SelfHealingQueueTest do
  use ExUnit.Case, async: false

  alias Muse.{Diagnostic, SelfHealingQueue, SelfHealingIssue}

  # -- Helpers ------------------------------------------------------------------

  defp stop_named(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp ensure_pubsub do
    case Process.whereis(Muse.PubSub) do
      nil ->
        {:ok, _} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Muse.PubSub}],
            strategy: :one_for_one
          )

        :ok

      _pid ->
        :ok
    end
  end

  defp start_queue(opts \\ []) do
    stop_named(Muse.SelfHealingQueue)
    {:ok, _} = SelfHealingQueue.start_link(opts)
    :ok
  end

  # -- Setup --------------------------------------------------------------------

  setup do
    ensure_pubsub()
    start_queue()

    on_exit(fn ->
      stop_named(Muse.SelfHealingQueue)
    end)

    :ok
  end

  # -- Tests --------------------------------------------------------------------

  test "starts empty" do
    assert SelfHealingQueue.list() == []
    assert SelfHealingQueue.queued() == []
  end

  test "add_diagnostic/1 creates an issue from a diagnostic" do
    diagnostic = Diagnostic.new(:warning, "test issue")
    issue = SelfHealingQueue.add_diagnostic(diagnostic)

    assert %SelfHealingIssue{} = issue
    assert issue.diagnostic_id == diagnostic.id
    assert issue.status == :queued
    assert issue.level == :warning
    assert issue.message == "test issue"
  end

  test "add_diagnostic/1 adds issue to list" do
    diagnostic = Diagnostic.new(:error, "backend error")
    SelfHealingQueue.add_diagnostic(diagnostic)

    [issue] = SelfHealingQueue.list()
    assert issue.diagnostic_id == diagnostic.id
  end

  test "add_diagnostic/1 rejects duplicate by diagnostic_id" do
    diagnostic = Diagnostic.new(:critical, "unique issue")
    SelfHealingQueue.add_diagnostic(diagnostic)
    result = SelfHealingQueue.add_diagnostic(diagnostic)

    assert result == {:error, :duplicate}
    assert length(SelfHealingQueue.list()) == 1
  end

  test "add_diagnostic/1 broadcasts :self_healing_issue_added" do
    :ok = SelfHealingQueue.subscribe()
    diagnostic = Diagnostic.new(:warning, "broadcast test")
    issue = SelfHealingQueue.add_diagnostic(diagnostic)

    assert_received {:self_healing_issue_added, ^issue}
  end

  test "add_issue/1 adds a pre-built issue" do
    diagnostic = Diagnostic.new(:error, "manual issue")
    issue = SelfHealingIssue.from_diagnostic(diagnostic)
    result = SelfHealingQueue.add_issue(issue)

    assert result == issue
    assert length(SelfHealingQueue.list()) == 1
  end

  test "add_issue/1 rejects duplicate by diagnostic_id" do
    diagnostic = Diagnostic.new(:error, "dup issue")
    issue1 = SelfHealingIssue.from_diagnostic(diagnostic)
    SelfHealingQueue.add_issue(issue1)
    # Another issue with same diagnostic_id
    issue2 = SelfHealingIssue.from_diagnostic(diagnostic)
    result = SelfHealingQueue.add_issue(issue2)

    assert result == {:error, :duplicate}
  end

  test "queued/0 returns only queued issues" do
    d1 = Diagnostic.new(:warning, "warning issue")
    issue1 = SelfHealingQueue.add_diagnostic(d1)
    SelfHealingQueue.mark_in_progress(issue1.id)

    d2 = Diagnostic.new(:error, "error issue")
    SelfHealingQueue.add_diagnostic(d2)

    queued = SelfHealingQueue.queued()
    assert length(queued) == 1
    assert hd(queued).status == :queued
  end

  test "remove/1 removes an issue by id" do
    diagnostic = Diagnostic.new(:warning, "removable")
    issue = SelfHealingQueue.add_diagnostic(diagnostic)

    assert :ok = SelfHealingQueue.remove(issue.id)
    assert SelfHealingQueue.list() == []
  end

  test "remove/1 returns error for missing id" do
    assert {:error, :not_found} = SelfHealingQueue.remove(999_999)
  end

  test "remove/1 broadcasts :self_healing_issue_removed" do
    :ok = SelfHealingQueue.subscribe()
    diagnostic = Diagnostic.new(:warning, "to remove")
    issue = SelfHealingQueue.add_diagnostic(diagnostic)
    # Clear the add message
    receive do
      {:self_healing_issue_added, _} -> :ok
    after
      100 -> :ok
    end

    :ok = SelfHealingQueue.remove(issue.id)
    assert_received {:self_healing_issue_removed, ^issue}
  end

  test "mark_in_progress/1 preserves list order" do
    d1 = Diagnostic.new(:warning, "first")
    d2 = Diagnostic.new(:error, "second")
    d3 = Diagnostic.new(:critical, "third")
    _i1 = SelfHealingQueue.add_diagnostic(d1)
    i2 = SelfHealingQueue.add_diagnostic(d2)
    i3 = SelfHealingQueue.add_diagnostic(d3)

    # Queue is newest-first: [i3, i2, i1]
    [stored_i3, _stored_i2, _stored_i1] = SelfHealingQueue.list()
    assert stored_i3.id == i3.id
    assert stored_i3.status == :queued

    SelfHealingQueue.mark_in_progress(i2.id)

    # After update, order should be preserved: [i3, i2(in_progress), i1]
    [after_i3, after_i2, after_i1] = SelfHealingQueue.list()
    assert after_i3.id == i3.id
    assert after_i3.status == :queued
    assert after_i2.id == i2.id
    assert after_i2.status == :in_progress
    assert after_i1.message == "first"
  end

  test "mark_in_progress/1 broadcasts update" do
    :ok = SelfHealingQueue.subscribe()
    diagnostic = Diagnostic.new(:error, "broadcast progress")
    issue = SelfHealingQueue.add_diagnostic(diagnostic)
    # Clear the add message
    receive do
      {:self_healing_issue_added, _} -> :ok
    after
      100 -> :ok
    end

    updated = SelfHealingQueue.mark_in_progress(issue.id)
    assert_received {:self_healing_issue_updated, ^updated}
  end

  test "mark_in_progress/1 returns error for missing id" do
    assert {:error, :not_found} = SelfHealingQueue.mark_in_progress(999_999)
  end

  test "mark_fixed/1 preserves list order" do
    d1 = Diagnostic.new(:warning, "first")
    d2 = Diagnostic.new(:error, "second")
    i1 = SelfHealingQueue.add_diagnostic(d1)
    i2 = SelfHealingQueue.add_diagnostic(d2)

    # Queue is newest-first: [i2, i1]
    SelfHealingQueue.mark_fixed(i1.id)

    # After update, order should be preserved: [i2, i1(fixed)]
    [after_i2, after_i1] = SelfHealingQueue.list()
    assert after_i2.id == i2.id
    assert after_i2.status == :queued
    assert after_i1.id == i1.id
    assert after_i1.status == :fixed
  end

  test "mark_fixed/1 returns error for missing id" do
    assert {:error, :not_found} = SelfHealingQueue.mark_fixed(999_999)
  end

  test "mark_failed/2 updates status and sets failure reason" do
    diagnostic = Diagnostic.new(:error, "failed test")
    issue = SelfHealingQueue.add_diagnostic(diagnostic)
    updated = SelfHealingQueue.mark_failed(issue.id, "compilation failed")

    assert updated.status == :failed
    assert updated.failure_reason == "compilation failed"
  end

  test "mark_failed/2 defaults to empty string reason" do
    diagnostic = Diagnostic.new(:error, "failed no reason")
    issue = SelfHealingQueue.add_diagnostic(diagnostic)
    updated = SelfHealingQueue.mark_failed(issue.id)

    assert updated.status == :failed
    assert updated.failure_reason == ""
  end

  test "mark_failed/2 returns error for missing id" do
    assert {:error, :not_found} = SelfHealingQueue.mark_failed(999_999, "nope")
  end

  test "clear_fixed/0 removes all fixed issues" do
    d1 = Diagnostic.new(:warning, "fixed1")
    issue1 = SelfHealingQueue.add_diagnostic(d1)
    SelfHealingQueue.mark_fixed(issue1.id)

    d2 = Diagnostic.new(:error, "still queued")
    SelfHealingQueue.add_diagnostic(d2)

    assert :ok = SelfHealingQueue.clear_fixed()
    remaining = SelfHealingQueue.list()
    assert length(remaining) == 1
    assert hd(remaining).message == "still queued"
  end

  # -- claim_queued/0 tests -----------------------------------------------------

  test "claim_queued/0 returns queued issues as in_progress" do
    d1 = Diagnostic.new(:warning, "claim me")
    d2 = Diagnostic.new(:error, "claim me too")
    SelfHealingQueue.add_diagnostic(d1)
    SelfHealingQueue.add_diagnostic(d2)

    claimed = SelfHealingQueue.claim_queued()

    assert length(claimed) == 2
    assert Enum.all?(claimed, &(&1.status == :in_progress))
  end

  test "claim_queued/0 updates queue state" do
    d1 = Diagnostic.new(:warning, "claimed")
    SelfHealingQueue.add_diagnostic(d1)

    SelfHealingQueue.claim_queued()

    assert SelfHealingQueue.queued() == []
    [updated] = SelfHealingQueue.list()
    assert updated.status == :in_progress
  end

  test "claim_queued/0 returns empty on second call" do
    Diagnostic.new(:warning, "once")
    |> SelfHealingQueue.add_diagnostic()

    first = SelfHealingQueue.claim_queued()
    assert length(first) == 1

    second = SelfHealingQueue.claim_queued()
    assert second == []
  end

  test "claim_queued/0 only claims queued, not in_progress or fixed" do
    d1 = Diagnostic.new(:warning, "already in progress")
    i1 = SelfHealingQueue.add_diagnostic(d1)
    SelfHealingQueue.mark_in_progress(i1.id)

    d2 = Diagnostic.new(:error, "already fixed")
    i2 = SelfHealingQueue.add_diagnostic(d2)
    SelfHealingQueue.mark_fixed(i2.id)

    d3 = Diagnostic.new(:critical, "still queued")
    SelfHealingQueue.add_diagnostic(d3)

    claimed = SelfHealingQueue.claim_queued()
    assert length(claimed) == 1
    assert hd(claimed).message == "still queued"
  end

  test "claim_queued/0 broadcasts updates for claimed issues" do
    :ok = SelfHealingQueue.subscribe()
    d1 = Diagnostic.new(:warning, "broadcast claim")
    issue = SelfHealingQueue.add_diagnostic(d1)
    # Clear the add message
    receive do
      {:self_healing_issue_added, _} -> :ok
    after
      100 -> :ok
    end

    [claimed] = SelfHealingQueue.claim_queued()
    assert claimed.id == issue.id
    assert_received {:self_healing_issue_updated, ^claimed}
  end

  test "claim_queued/0 preserves list order" do
    d1 = Diagnostic.new(:warning, "first")
    d2 = Diagnostic.new(:error, "second")
    d3 = Diagnostic.new(:critical, "third")
    i1 = SelfHealingQueue.add_diagnostic(d1)
    i2 = SelfHealingQueue.add_diagnostic(d2)
    i3 = SelfHealingQueue.add_diagnostic(d3)

    SelfHealingQueue.claim_queued()

    # Order: [i3, i2, i1] — all now in_progress
    [s3, s2, s1] = SelfHealingQueue.list()
    assert s3.id == i3.id
    assert s3.status == :in_progress
    assert s2.id == i2.id
    assert s2.status == :in_progress
    assert s1.id == i1.id
    assert s1.status == :in_progress
  end

  test "clear_fixed/0 broadcasts :self_healing_issues_cleared when fixed issues exist" do
    :ok = SelfHealingQueue.subscribe()
    diagnostic = Diagnostic.new(:warning, "to fix")
    issue = SelfHealingQueue.add_diagnostic(diagnostic)
    SelfHealingQueue.mark_fixed(issue.id)
    # Clear previous messages
    receive do
      {:self_healing_issue_added, _} -> :ok
    after
      100 -> :ok
    end

    receive do
      {:self_healing_issue_updated, _} -> :ok
    after
      100 -> :ok
    end

    :ok = SelfHealingQueue.clear_fixed()
    assert_received {:self_healing_issues_cleared, [_fixed_issue]}
  end

  test "clear_fixed/0 does not broadcast when there are no fixed issues" do
    :ok = SelfHealingQueue.subscribe()
    d1 = Diagnostic.new(:warning, "still queued")
    SelfHealingQueue.add_diagnostic(d1)

    # Clear previous messages
    receive do
      {:self_healing_issue_added, _} -> :ok
    after
      100 -> :ok
    end

    :ok = SelfHealingQueue.clear_fixed()
    refute_received {:self_healing_issues_cleared, _}
  end

  test "keeps bounded list with max option" do
    stop_named(Muse.SelfHealingQueue)
    {:ok, _} = SelfHealingQueue.start_link(max: 2)

    d1 = Diagnostic.new(:warning, "one")
    d2 = Diagnostic.new(:error, "two")
    d3 = Diagnostic.new(:critical, "three")

    SelfHealingQueue.add_diagnostic(d1)
    SelfHealingQueue.add_diagnostic(d2)
    SelfHealingQueue.add_diagnostic(d3)

    assert length(SelfHealingQueue.list()) == 2
  end

  test "subscribe/0 returns :ok when PubSub available" do
    assert :ok = SelfHealingQueue.subscribe()
  end
end
