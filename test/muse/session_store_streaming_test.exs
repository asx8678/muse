defmodule Muse.SessionStoreStreamingTest do
  @moduledoc """
  T1-17: Streaming JSONL persistence reads, imports, exports, and patch lookup.

  Tests verify that:
  - Large JSONL files are read incrementally (line-bounded memory)
  - Streaming API variants yield decoded maps lazily
  - find_patch/3 locates patches without loading all patches
  - Import writes entries one at a time (no giant intermediate strings)
  - Corrupted/truncated JSONL lines are handled with tolerant-skip philosophy
  - Existing JSONL format and parsing semantics are preserved
  """
  use ExUnit.Case, async: false

  alias Muse.SessionStore

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    base_dir = tmp_dir!()
    session_id = "streaming-#{System.unique_integer([:positive])}"

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{base_dir: base_dir, session_id: session_id}
  end

  defp tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path = Path.join(System.tmp_dir!(), "muse-streaming-test-#{suffix}")
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

  defp generate_jsonl_lines(count, opts \\ []) do
    corrupt_every = Keyword.get(opts, :corrupt_every, nil)

    for i <- 1..count do
      if corrupt_every && rem(i, corrupt_every) == 0 do
        "CORRUPT_LINE_#{i}"
      else
        Jason.encode!(%{id: i, type: "event", data: %{n: i}})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming reads — load_events/2 now uses File.stream!
  # ---------------------------------------------------------------------------

  describe "streaming load_events/2 — large JSONL files" do
    test "reads 10,000 event lines correctly", %{base_dir: base_dir, session_id: sid} do
      lines = generate_jsonl_lines(10_000)
      content = Enum.join(lines, "\n") <> "\n"
      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 10_000

      # Verify order is preserved (oldest first)
      assert Enum.at(events, 0)["id"] == 1
      assert Enum.at(events, 9_999)["id"] == 10_000
    end

    test "reads 10,000 lines with 100 corrupt lines interspersed", %{
      base_dir: base_dir,
      session_id: sid
    } do
      lines = generate_jsonl_lines(10_000, corrupt_every: 100)
      content = Enum.join(lines, "\n") <> "\n"
      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 100}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 9_900
    end

    test "handles messages.jsonl with streaming", %{base_dir: base_dir, session_id: sid} do
      lines = generate_jsonl_lines(5_000)
      content = Enum.join(lines, "\n") <> "\n"
      write_jsonl(base_dir, sid, "messages.jsonl", content)

      assert {:ok, messages, %{skipped: 0}} = SessionStore.load_messages(base_dir, sid)
      assert length(messages) == 5_000
    end

    test "handles patches.jsonl with streaming", %{base_dir: base_dir, session_id: sid} do
      lines =
        for i <- 1..3_000 do
          Jason.encode!(%{patch_id: "p#{i}", status: "proposed", hash: "h#{i}"})
        end

      content = Enum.join(lines, "\n") <> "\n"
      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, patches, %{skipped: 0}} = SessionStore.load_patches(base_dir, sid)
      assert length(patches) == 3_000
    end
  end

  describe "streaming load — performance characteristics" do
    test "loads 20,000 lines in under 10 seconds", %{base_dir: base_dir, session_id: sid} do
      lines = generate_jsonl_lines(20_000)
      content = Enum.join(lines, "\n") <> "\n"
      write_jsonl(base_dir, sid, "events.jsonl", content)

      {time_us, result} =
        :timer.tc(fn -> SessionStore.load_events(base_dir, sid) end)

      time_ms = div(time_us, 1_000)

      assert {:ok, events, %{skipped: 0}} = result
      assert length(events) == 20_000
      assert time_ms < 10_000, "load_events took #{time_ms}ms for 20K lines — regression"
    end
  end

  describe "streaming load — edge cases" do
    test "empty file returns empty list with zero skipped", %{base_dir: base_dir, session_id: sid} do
      write_jsonl(base_dir, sid, "events.jsonl", "")
      assert {:ok, [], %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
    end

    test "missing file returns empty list with zero skipped", %{
      base_dir: base_dir,
      session_id: sid
    } do
      assert {:ok, [], %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
    end

    test "single valid line", %{base_dir: base_dir, session_id: sid} do
      write_jsonl(base_dir, sid, "events.jsonl", ~s|{"id":1,"type":"test"}\n|)

      assert {:ok, [event], %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert event["id"] == 1
    end

    test "single corrupt line", %{base_dir: base_dir, session_id: sid} do
      write_jsonl(base_dir, sid, "events.jsonl", "NOT_JSON\n")

      assert {:ok, [], %{skipped: 1}} = SessionStore.load_events(base_dir, sid)
    end

    test "blank lines between valid entries do not count as skipped", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = ~s|{"id":1}\n\n\n{"id":2}\n|
      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 2
    end

    test "trailing newline does not produce extra entry or skip", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = ~s|{"id":1}\n{"id":2}\n|
      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 2
    end

    test "partial last line (truncated JSON) counts as skipped", %{
      base_dir: base_dir,
      session_id: sid
    } do
      write_jsonl(base_dir, sid, "events.jsonl", ~s|{"id":1}\n{"id":2\n|)

      assert {:ok, events, %{skipped: 1}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 1
    end

    test "file with only blank lines", %{base_dir: base_dir, session_id: sid} do
      write_jsonl(base_dir, sid, "events.jsonl", "\n\n\n\n")
      assert {:ok, [], %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
    end

    test "invalid session ID returns error", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.load_events(base_dir, "../escape")
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming API — stream_events/2, stream_messages/2, stream_patches/2
  # ---------------------------------------------------------------------------

  describe "stream_events/2 — lazy streaming API" do
    test "returns a stream of decoded events", %{base_dir: base_dir, session_id: sid} do
      lines = generate_jsonl_lines(100)
      content = Enum.join(lines, "\n") <> "\n"
      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, stream} = SessionStore.stream_events(base_dir, sid)

      # Stream is lazy — consuming only what's needed
      first_10 = Enum.take(stream, 10)
      assert length(first_10) == 10
      assert Enum.at(first_10, 0)["id"] == 1
    end

    test "stream skips corrupt lines", %{base_dir: base_dir, session_id: sid} do
      content = ~s|{"id":1}\nCORRUPT\n{"id":2}\n{"id":3}\n|
      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, stream} = SessionStore.stream_events(base_dir, sid)
      events = Enum.to_list(stream)
      assert length(events) == 3
      assert Enum.map(events, & &1["id"]) == [1, 2, 3]
    end

    test "stream returns error for missing file", %{base_dir: base_dir, session_id: sid} do
      assert {:error, :enoent} = SessionStore.stream_events(base_dir, sid)
    end

    test "stream returns error for invalid session ID", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.stream_events(base_dir, "../escape")
    end

    test "stream can be consumed partially with Enum.take", %{
      base_dir: base_dir,
      session_id: sid
    } do
      lines = generate_jsonl_lines(1_000)
      content = Enum.join(lines, "\n") <> "\n"
      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, stream} = SessionStore.stream_events(base_dir, sid)
      first_5 = Enum.take(stream, 5)
      assert length(first_5) == 5
      assert Enum.at(first_5, 0)["id"] == 1
      assert Enum.at(first_5, 4)["id"] == 5
    end
  end

  describe "stream_messages/2 — lazy streaming API" do
    test "returns a stream of decoded messages", %{base_dir: base_dir, session_id: sid} do
      content = ~s|{"role":"user","content":"hi"}\n{"role":"assistant","content":"hello"}\n|
      write_jsonl(base_dir, sid, "messages.jsonl", content)

      assert {:ok, stream} = SessionStore.stream_messages(base_dir, sid)
      messages = Enum.to_list(stream)
      assert length(messages) == 2
    end
  end

  describe "stream_patches/2 — lazy streaming API" do
    test "returns a stream of decoded patches", %{base_dir: base_dir, session_id: sid} do
      content =
        ~s|{"patch_id":"p1","status":"proposed"}\n{"patch_id":"p2","status":"approved"}\n|

      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, stream} = SessionStore.stream_patches(base_dir, sid)
      patches = Enum.to_list(stream)
      assert length(patches) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # find_patch/3 — targeted lookup without loading all patches
  # ---------------------------------------------------------------------------

  describe "find_patch/3 — targeted patch lookup" do
    test "finds patch by id", %{base_dir: base_dir, session_id: sid} do
      patches =
        for i <- 1..100 do
          %{
            "id" => "patch-#{i}",
            "patch_id" => "pid-#{i}",
            "hash" => "h#{i}",
            "status" => "proposed"
          }
        end

      encoded = patches |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
      content = encoded <> "\n"

      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, found} = SessionStore.find_patch(base_dir, sid, "patch-42")
      assert found["id"] == "patch-42"
    end

    test "finds patch by patch_id", %{base_dir: base_dir, session_id: sid} do
      content = ~s|{"patch_id":"pid-target","status":"approved"}\n|
      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, found} = SessionStore.find_patch(base_dir, sid, "pid-target")
      assert found["patch_id"] == "pid-target"
    end

    test "finds patch by hash", %{base_dir: base_dir, session_id: sid} do
      content = ~s|{"hash":"hash-target","status":"approved"}\n|
      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, found} = SessionStore.find_patch(base_dir, sid, "hash-target")
      assert found["hash"] == "hash-target"
    end

    test "returns not_found when no patch matches", %{base_dir: base_dir, session_id: sid} do
      content = ~s|{"id":"p1","patch_id":"p1","hash":"h1"}\n|
      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:error, :not_found} = SessionStore.find_patch(base_dir, sid, "nonexistent")
    end

    test "returns not_found when patches.jsonl does not exist", %{
      base_dir: base_dir,
      session_id: sid
    } do
      assert {:error, :not_found} = SessionStore.find_patch(base_dir, sid, "any")
    end

    test "skips corrupt lines and still finds valid patch", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = ~s|CORRUPT\n{"id":"target","hash":"ht","status":"approved"}\n|
      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, found} = SessionStore.find_patch(base_dir, sid, "target")
      assert found["id"] == "target"
    end

    test "returns not_found when all lines are corrupt", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = ~s|CORRUPT1\nCORRUPT2\n|
      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:error, :not_found} = SessionStore.find_patch(base_dir, sid, "any")
    end

    test "finds first matching patch (stops early)", %{
      base_dir: base_dir,
      session_id: sid
    } do
      # Two patches with the same id — find_patch returns the first
      content =
        ~s|{"id":"dup","seq":1}\n{"id":"dup","seq":2}\n|

      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, found} = SessionStore.find_patch(base_dir, sid, "dup")
      assert found["seq"] == 1
    end

    test "finds patch in large file without loading all patches", %{
      base_dir: base_dir,
      session_id: sid
    } do
      # Create 5,000 patches with the target at position 2500
      patches =
        for i <- 1..5000 do
          if i == 2500 do
            %{"id" => "target-patch", "patch_id" => "tp", "hash" => "th", "index" => i}
          else
            %{"id" => "p#{i}", "patch_id" => "pid#{i}", "hash" => "h#{i}", "index" => i}
          end
        end

      encoded = patches |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
      content = encoded <> "\n"

      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, found} = SessionStore.find_patch(base_dir, sid, "target-patch")
      assert found["id"] == "target-patch"
      assert found["index"] == 2500
    end

    test "rejects invalid session ID", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.find_patch(base_dir, "../escape", "any")
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming import — writes JSONL entries one at a time
  # ---------------------------------------------------------------------------

  describe "streaming import_session/3 — line-by-line writes" do
    test "imports a session with many events correctly", %{
      base_dir: base_dir,
      session_id: sid
    } do
      events = for i <- 1..500, do: %{"id" => i, "type" => "event"}
      messages = for i <- 1..200, do: %{"role" => "user", "content" => "msg#{i}"}
      patches = for i <- 1..50, do: %{"patch_id" => "p#{i}", "status" => "approved"}

      export = %{
        "session_id" => sid,
        "export_schema_version" => 1,
        "snapshot" => %{"status" => "idle", "objective" => "Stream import"},
        "events" => events,
        "messages" => messages,
        "patches" => patches
      }

      assert {:ok, ^sid} = SessionStore.import_session(base_dir, export)

      assert {:ok, loaded_events, %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert length(loaded_events) == 500
      assert Enum.at(loaded_events, 0)["id"] == 1
      assert Enum.at(loaded_events, 499)["id"] == 500

      assert {:ok, loaded_messages, %{skipped: 0}} = SessionStore.load_messages(base_dir, sid)
      assert length(loaded_messages) == 200

      assert {:ok, loaded_patches, %{skipped: 0}} = SessionStore.load_patches(base_dir, sid)
      assert length(loaded_patches) == 50
    end

    test "import with empty lists creates empty JSONL files", %{
      base_dir: base_dir,
      session_id: sid
    } do
      export = %{
        "session_id" => sid,
        "export_schema_version" => 1,
        "snapshot" => %{"status" => "idle"},
        "events" => [],
        "messages" => [],
        "patches" => []
      }

      assert {:ok, ^sid} = SessionStore.import_session(base_dir, export)

      assert {:ok, [], %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert {:ok, [], %{skipped: 0}} = SessionStore.load_messages(base_dir, sid)
      assert {:ok, [], %{skipped: 0}} = SessionStore.load_patches(base_dir, sid)
    end

    test "import rejects unencodable data before writing", %{base_dir: base_dir} do
      export = %{
        "session_id" => "unencodable-streaming",
        "snapshot" => %{"status" => "idle"},
        "events" => [%{"bad" => fn -> :ok end}],
        "messages" => [],
        "patches" => []
      }

      assert {:error, {:encode_failed, _reason}} = SessionStore.import_session(base_dir, export)
      # Session directory should not exist since no files were written
      refute SessionStore.session_exists?(base_dir, "unencodable-streaming")
    end

    test "import round-trips with export correctly", %{
      base_dir: base_dir,
      session_id: sid
    } do
      SessionStore.save_session(base_dir, sid, %{"objective" => "Round-trip streaming"})
      SessionStore.append_event(base_dir, sid, %{"type" => "test", "seq" => 1})
      SessionStore.append_event(base_dir, sid, %{"type" => "test", "seq" => 2})
      SessionStore.append_message(base_dir, sid, %{"role" => "user", "content" => "hi"})

      assert {:ok, export} = SessionStore.export_session(base_dir, sid)

      new_id = "#{sid}-imported"
      assert {:ok, ^new_id} = SessionStore.import_session(base_dir, export, session_id: new_id)

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, new_id)
      assert length(events) == 2
    end

    test "import with memory artifact", %{base_dir: base_dir, session_id: sid} do
      export = %{
        "session_id" => sid,
        "export_schema_version" => 1,
        "snapshot" => %{"status" => "idle"},
        "events" => [],
        "messages" => [],
        "patches" => [],
        "memory" => %{"user_goal" => "Streaming test"}
      }

      assert {:ok, ^sid} = SessionStore.import_session(base_dir, export)
      assert {:ok, memory} = SessionStore.load_memory(base_dir, sid)
      assert memory["user_goal"] == "Streaming test"
    end
  end

  # ---------------------------------------------------------------------------
  # Export — benefits from streaming reads
  # ---------------------------------------------------------------------------

  describe "export_session/2 — with streaming reads" do
    test "exports a session with many events", %{base_dir: base_dir, session_id: sid} do
      SessionStore.save_session(base_dir, sid, %{"objective" => "Large export"})

      for i <- 1..500 do
        SessionStore.append_event(base_dir, sid, %{"type" => "event", "seq" => i})
      end

      assert {:ok, export} = SessionStore.export_session(base_dir, sid)
      assert length(export["events"]) == 500
      assert export["snapshot"]["objective"] == "Large export"
    end

    test "export handles sessions with corrupt JSONL", %{
      base_dir: base_dir,
      session_id: sid
    } do
      SessionStore.save_session(base_dir, sid, %{"objective" => "Corrupt export"})

      dir = SessionStore.session_dir(base_dir, sid)
      # Write events with a corrupt line
      File.write!(Path.join(dir, "events.jsonl"), ~s|{"id":1}\nCORRUPT\n{"id":2}\n|)

      assert {:ok, export} = SessionStore.export_session(base_dir, sid)
      # Corrupt line is skipped; valid events are included
      assert length(export["events"]) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Append — streaming append still works correctly
  # ---------------------------------------------------------------------------

  describe "append_jsonl — streaming append correctness" do
    test "appends events to existing JSONL file", %{base_dir: base_dir, session_id: sid} do
      # Pre-populate with some events
      write_jsonl(base_dir, sid, "events.jsonl", ~s|{"id":1}\n|)

      assert :ok = SessionStore.append_event(base_dir, sid, %{"id" => 2})
      assert :ok = SessionStore.append_event(base_dir, sid, %{"id" => 3})

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 3
      assert Enum.map(events, & &1["id"]) == [1, 2, 3]
    end

    test "appends to non-existent file creates it", %{base_dir: base_dir, session_id: sid} do
      assert :ok = SessionStore.append_event(base_dir, sid, %{"id" => 1})

      assert {:ok, [event], %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert event["id"] == 1
    end

    test "large number of sequential appends", %{base_dir: base_dir, session_id: sid} do
      for i <- 1..100 do
        assert :ok = SessionStore.append_event(base_dir, sid, %{"id" => i})
      end

      assert {:ok, events, %{skipped: 0}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 100
      assert Enum.map(events, & &1["id"]) == Enum.to_list(1..100)
    end
  end

  # ---------------------------------------------------------------------------
  # Corrupt line handling — preserves tolerant-skip philosophy
  # ---------------------------------------------------------------------------

  describe "corrupt line handling — streaming reads" do
    test "mixed valid/invalid/blank lines in events.jsonl", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = ~s|{"id":1}\n\n{bad\n{"id":2}\n   \n{"id":3}\nalso bad\n|
      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, events, %{skipped: 2}} = SessionStore.load_events(base_dir, sid)
      assert length(events) == 3
    end

    test "binary garbage line is skipped", %{base_dir: base_dir, session_id: sid} do
      File.mkdir_p!(SessionStore.session_dir(base_dir, sid))
      path = Path.join(SessionStore.session_dir(base_dir, sid), "events.jsonl")
      File.write!(path, <<0, 0, 0, 0, 255, 254, 253>>)

      assert {:ok, [], %{skipped: 1}} = SessionStore.load_events(base_dir, sid)
    end

    test "all corrupt lines in patches returns empty with skipped count", %{
      base_dir: base_dir,
      session_id: sid
    } do
      content = "garbage\nbad\ncorrupt\n"
      write_jsonl(base_dir, sid, "patches.jsonl", content)

      assert {:ok, [], %{skipped: 3}} = SessionStore.load_patches(base_dir, sid)
    end

    test "stream_events skips corrupt lines", %{base_dir: base_dir, session_id: sid} do
      content = ~s|{"id":1}\nNOT_JSON\n{"id":2}\n|
      write_jsonl(base_dir, sid, "events.jsonl", content)

      assert {:ok, stream} = SessionStore.stream_events(base_dir, sid)
      events = Enum.to_list(stream)
      assert length(events) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Session ID validation — consistent error handling
  # ---------------------------------------------------------------------------

  describe "streaming API — session ID validation" do
    test "stream_messages rejects invalid session ID", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.stream_messages(base_dir, "../escape")
    end

    test "stream_patches rejects invalid session ID", %{base_dir: base_dir} do
      assert {:error, {:invalid_session_id, "../escape"}} =
               SessionStore.stream_patches(base_dir, "../escape")
    end
  end
end
