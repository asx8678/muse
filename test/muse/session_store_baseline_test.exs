defmodule Muse.SessionStoreBaselineTest do
  @moduledoc """
  T0-00 Baseline: SessionStore JSONL invalid-line behavior.

  These tests verify that `SessionStore.load_events/2` and
  `load_messages/2` correctly skip corrupt JSON lines, report
  the `skipped` count, and preserve valid lines — without crashing.
  """
  use ExUnit.Case, async: false

  alias Muse.SessionStore

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    base_dir = tmp_dir!()
    session_id = "baseline-#{System.unique_integer([:positive])}"

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir, session_id: session_id}
  end

  defp tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path = Path.join(System.tmp_dir!(), "muse-store-baseline-#{suffix}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp write_jsonl(base_dir, session_id, file_name, content) do
    dir = SessionStore.session_dir(base_dir, session_id)
    File.mkdir_p!(dir)
    path = Path.join(dir, file_name)
    File.write!(path, content)
  end

  # ---------------------------------------------------------------------------
  # load_events — invalid line behavior
  # ---------------------------------------------------------------------------

  describe "load_events/2 — JSONL invalid-line behavior" do
    test "skips corrupt JSON lines and reports skipped count", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = """
      {"id":1,"type":"user_message","data":{"text":"hello"}}
      NOT VALID JSON
      {"id":2,"type":"assistant_message","data":{"text":"hi"}}
      {broken json
      {"id":3,"type":"user_message","data":{"text":"bye"}}
      """

      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 2}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 3

      # Verify the valid events were loaded in order
      ids = Enum.map(events, & &1["id"])
      assert ids == [1, 2, 3]
    end

    test "handles file with only invalid lines", %{base_dir: base_dir, session_id: sid} do
      content = """
      not json
      also not json
      {still broken}
      """

      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, [], %{skipped: 3}} = SessionStore.load_events(base_dir, sid)
    end

    test "handles empty JSONL file (no lines)", %{base_dir: base_dir, session_id: sid} do
      write_jsonl(base_dir, sid, "events.jsonl", "")

      assert {:ok, [], %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
    end

    test "handles JSONL with trailing newline producing empty last line", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = "{\"id\":1}\n{\"id\":2}\n"

      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 2
    end

    test "handles JSONL with blank lines between valid entries", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = "{\"id\":1}\n\n{\"id\":2}\n\n\n{\"id\":3}\n"

      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 3
    end

    test "handles mixed valid/invalid/blank lines", %{base_dir: base_dir, session_id: sid} do
      content = "{\"id\":1}\n\n{bad\n{\"id\":2}\n   \n{\"id\":3}\nalso bad\n"

      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 2}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # load_messages — same invalid-line semantics
  # ---------------------------------------------------------------------------

  describe "load_messages/2 — JSONL invalid-line behavior" do
    test "skips corrupt JSON lines and reports skipped count", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = """
      {"role":"user","content":"hi"}
      bad line
      {"role":"assistant","content":"hello"}
      """

      write_jsonl(base_dir, sid, "messages.jsonl", content)

      assert {:ok, messages, %{skipped: 1}} = SessionStore.load_messages(base_dir, sid)
      assert length(messages) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # load_patches — same invalid-line semantics
  # ---------------------------------------------------------------------------

  describe "load_patches/2 — JSONL invalid-line behavior" do
    test "skips corrupt JSON lines and reports skipped count", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = """
      {"patch_id":"p1","status":"proposed"}
      corrupted
      {"patch_id":"p2","status":"approved"}
      """

      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, patches, %{skipped: 1}} = SessionStore.load_patches(base_dir, sid)
      assert length(patches) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Scale — large JSONL files
  # ---------------------------------------------------------------------------

  describe "load_events/2 — large JSONL files" do
    test "loads 1,000 valid event lines", %{base_dir: base_dir, session_id: sid} do
      lines = for i <- 1..1000, do: Jason.encode!(%{id: i, type: "user_message"})
      content = Enum.join(lines, "\n") <> "\n"

      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 1_000
    end

    test "loads 1,000 lines with 10 corrupt lines interspersed", %{
      base_dir: base_dir,
      session_id: sid
    } do
      lines =
        for i <- 1..1000 do
          if rem(i, 100) == 0 do
            "corrupt_line_#{i}"
          else
            Jason.encode!(%{id: i, type: "user_message"})
          end
        end

      content = Enum.join(lines, "\n") <> "\n"

      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 10}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 990
    end

    test "loads 5,000 valid event lines in under 5 seconds", %{
      base_dir: base_dir,
      session_id: sid
    } do
      lines = for i <- 1..5000, do: Jason.encode!(%{id: i, type: "event", data: %{n: i}})
      content = Enum.join(lines, "\n") <> "\n"

      write_jsonl(base_dir, sid, "events.jsonl", content)

      {time_us, result} =
        :timer.tc(fn -> SessionStore.load_events(base_dir, sid) end)

      time_ms = div(time_us, 1_000)

      assert {:ok, events, %{skipped: 0}} = result
      assert length(events) == 5_000

      assert time_ms < 5_000,
             "load_events took #{time_ms}ms for 5K lines — possible regression"
    end
  end

  # ---------------------------------------------------------------------------
  # Session ID validation — baseline
  # ---------------------------------------------------------------------------

  describe "session ID validation — baseline" do
    test "valid session IDs are accepted" do
      assert :ok = SessionStore.validate_session_id("abc-123")
      assert :ok = SessionStore.validate_session_id("session_with_underscores")
      assert :ok = SessionStore.validate_session_id("a")
    end

    test "invalid session IDs are rejected" do
      assert {:error, {:invalid_session_id, ""}} = SessionStore.validate_session_id("")
      assert {:error, {:invalid_session_id, "."}} = SessionStore.validate_session_id(".")
      assert {:error, {:invalid_session_id, ".."}} = SessionStore.validate_session_id("..")

      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.validate_session_id("../escape")

      assert {:error, {:invalid_session_id, "foo\\bar"}} =
               SessionStore.validate_session_id("foo\\bar")

      too_long = String.duplicate("a", 256)

      assert {:error, {:invalid_session_id, ^too_long}} =
               SessionStore.validate_session_id(too_long)
    end

    test "non-binary session IDs are rejected" do
      assert {:error, {:invalid_session_id, :atom}} = SessionStore.validate_session_id(:atom)
      assert {:error, {:invalid_session_id, 123}} = SessionStore.validate_session_id(123)
      assert {:error, {:invalid_session_id, nil}} = SessionStore.validate_session_id(nil)
    end
  end
end
