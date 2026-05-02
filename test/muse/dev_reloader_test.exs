defmodule Muse.DevReloaderTest do
  use ExUnit.Case, async: false

  alias Muse.DevReloader
  alias Muse.Diagnostics
  alias Muse.State

  # -- Helpers ------------------------------------------------------------------

  defp stop_reloader do
    case Process.whereis(Muse.DevReloader) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp stop_state do
    case Process.whereis(Muse.State) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp stop_diagnostics do
    case Process.whereis(Muse.Diagnostics) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  defp safe_stop(pid) do
    try do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp start_state do
    stop_state()
    {:ok, _} = State.start_link()
    :ok
  end

  defp start_diagnostics do
    stop_diagnostics()
    {:ok, _} = Diagnostics.start_link(install_logger_handler?: false)
    :ok
  end

  defp start_reloader(opts \\ []) do
    stop_reloader()
    default_opts = [poll?: false]
    {:ok, _} = DevReloader.start_link(Keyword.merge(default_opts, opts))
    :ok
  end

  # -- Setup --------------------------------------------------------------------

  setup do
    Muse.Diagnostics.LoggerHandler.remove()
    start_state()
    start_diagnostics()
    start_reloader()

    on_exit(fn ->
      Muse.Diagnostics.LoggerHandler.remove()
      stop_reloader()
      stop_diagnostics()
      stop_state()
    end)

    :ok
  end

  # -- Tests --------------------------------------------------------------------

  describe "status/0" do
    test "returns initial state" do
      status = DevReloader.status()

      assert status.generation == 0
      assert status.last_error == nil
      assert status.last_reload_at == nil
      assert status.pending_changes == nil
    end
  end

  describe "reload/0 — success" do
    test "increments generation" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      assert :ok = DevReloader.reload()
      status = DevReloader.status()
      assert status.generation == 1
    end

    test "clears last_error" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> {:error, "first boom"} end)

      assert {:error, "first boom"} = DevReloader.reload()

      # Restart with working funs to clear error
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      assert :ok = DevReloader.reload()
      assert DevReloader.status().last_error == nil
    end

    test "sets last_reload_at" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      before = DateTime.utc_now()
      assert :ok = DevReloader.reload()
      after_dt = DateTime.utc_now()

      reloaded_at = DevReloader.status().last_reload_at
      assert DateTime.compare(reloaded_at, before) in [:gt, :eq]
      assert DateTime.compare(reloaded_at, after_dt) in [:lt, :eq]
    end

    test "appends :reload_success event via State" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      assert :ok = DevReloader.reload()

      events = State.events()
      success_events = Enum.filter(events, &(&1.type == :reload_success))
      assert length(success_events) >= 1

      event = hd(success_events)
      assert event.source == :dev_reloader
      assert event.data.generation == 1
      assert is_list(event.data.files)
    end
  end

  describe "reload/0 — compile failure" do
    test "returns error and keeps GenServer alive" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> {:error, "compile boom"} end)

      assert {:error, "compile boom"} = DevReloader.reload()

      # GenServer is still alive — status/0 works
      status = DevReloader.status()
      assert status.generation == 0
      assert status.last_error == "compile boom"
    end

    test "appends :reload_failed event via State" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> {:error, "compile boom"} end)

      assert {:error, "compile boom"} = DevReloader.reload()

      events = State.events()
      failed_events = Enum.filter(events, &(&1.type == :reload_failed))
      assert length(failed_events) >= 1

      event = hd(failed_events)
      assert event.source == :dev_reloader
      assert event.data.error == "compile boom"
    end

    test "emits a backend diagnostic" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> {:error, "compile boom"} end)

      assert {:error, "compile boom"} = DevReloader.reload()

      [diagnostic | _] = Diagnostics.list()
      assert diagnostic.level == :error
      assert diagnostic.message == "Reload failed: compile boom"
      assert is_list(diagnostic.metadata.files)
    end

    test "does not crash when Diagnostics is unavailable" do
      stop_diagnostics()
      stop_reloader()
      start_reloader(compile_fun: fn _files -> {:error, "compile boom"} end)

      assert {:error, "compile boom"} = DevReloader.reload()

      start_diagnostics()
    end
  end

  describe "reload/0 — health check failure" do
    test "returns error and sets last_error" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> raise "health boom" end)

      assert {:error, error} = DevReloader.reload()
      assert error =~ "health boom"

      status = DevReloader.status()
      assert status.generation == 0
      assert status.last_error =~ "health boom"
    end

    test "GenServer stays alive after health check failure" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> raise "boom" end)

      assert {:error, _} = DevReloader.reload()

      # Can call status again — process didn't crash
      status = DevReloader.status()
      assert is_map(status)
    end

    test "emits a backend diagnostic" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> raise "health boom" end)

      assert {:error, error} = DevReloader.reload()

      [diagnostic | _] = Diagnostics.list()
      assert diagnostic.level == :error
      assert diagnostic.message == "Reload failed: #{error}"
      assert is_list(diagnostic.metadata.files)
    end
  end

  describe "rollback/0" do
    test "with no snapshot returns error" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      # No reload yet, so no snapshot
      assert {:error, reason} = DevReloader.rollback()
      assert reason =~ "no snapshot"
    end

    test "after successful reload returns :ok" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      assert :ok = DevReloader.reload()
      assert :ok = DevReloader.rollback()
    end

    test "after successful reload appends :rollback_success event" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      assert :ok = DevReloader.reload()
      assert :ok = DevReloader.rollback()

      events = State.events()
      rollback_events = Enum.filter(events, &(&1.type == :rollback_success))
      assert length(rollback_events) >= 1

      event = hd(rollback_events)
      assert event.source == :dev_reloader
      assert event.data.generation == 1
    end

    test "does not crash when State is unavailable" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      assert :ok = DevReloader.reload()

      # Kill State — rollback should still succeed (best-effort broadcast)
      stop_state()

      assert :ok = DevReloader.rollback()

      # Restart State for other tests
      start_state()
    end
  end

  describe "scan_mtimes/1 and find_changed/3" do
    test "detects changed files" do
      tmp_dir = System.tmp_dir!()
      file = Path.join(tmp_dir, "muse_scan_#{System.unique_integer([:positive])}.ex")
      File.write!(file, "defmodule Foo do end")

      try do
        mtimes1 = DevReloader.scan_mtimes([file])
        assert Map.has_key?(mtimes1, file)

        # Ensure mtime differs (some filesystems have 1s+ resolution)
        Process.sleep(1100)
        File.write!(file, "defmodule Bar do end")

        mtimes2 = DevReloader.scan_mtimes([file])
        changed = DevReloader.find_changed(mtimes1, mtimes2, [])
        assert file in changed
      after
        File.rm(file)
      end
    end

    test "excludes files matching exclude list" do
      tmp_dir = System.tmp_dir!()
      suffix = System.unique_integer([:positive])
      file1 = Path.join(tmp_dir, "muse_keep_#{suffix}.ex")
      file2 = Path.join(tmp_dir, "muse_skip_#{suffix}.ex")
      File.write!(file1, "defmodule A do end")
      File.write!(file2, "defmodule B do end")

      try do
        mtimes1 = DevReloader.scan_mtimes([file1, file2])
        Process.sleep(1100)
        File.write!(file1, "defmodule C do end")
        File.write!(file2, "defmodule D do end")

        mtimes2 = DevReloader.scan_mtimes([file1, file2])
        changed = DevReloader.find_changed(mtimes1, mtimes2, [file2])

        assert file1 in changed
        refute file2 in changed
      after
        File.rm(file1)
        File.rm(file2)
      end
    end

    test "handles non-existent globs gracefully" do
      mtimes = DevReloader.scan_mtimes(["/nonexistent/glob/*.ex"])
      assert mtimes == %{}
    end
  end

  describe "snapshot/restore" do
    test "snapshot_modules returns a map of Muse modules" do
      snapshot = DevReloader.snapshot_modules()
      assert is_map(snapshot)

      # At minimum, Muse itself should be in the snapshot
      assert Map.has_key?(snapshot, Muse)
    end

    test "restore_snapshot with empty map is a no-op" do
      assert :ok = DevReloader.restore_snapshot(%{})
    end
  end

  describe "multiple reloads" do
    test "generation increments on each success" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      assert :ok = DevReloader.reload()
      assert DevReloader.status().generation == 1

      assert :ok = DevReloader.reload()
      assert DevReloader.status().generation == 2

      assert :ok = DevReloader.reload()
      assert DevReloader.status().generation == 3
    end

    test "failure does not increment generation" do
      stop_reloader()
      start_reloader(compile_fun: fn _files -> :ok end, health_fun: fn -> :ok end)

      assert :ok = DevReloader.reload()
      assert DevReloader.status().generation == 1

      # Restart with failing compile
      stop_reloader()
      start_reloader(compile_fun: fn _files -> {:error, "nope"} end)

      assert {:error, "nope"} = DevReloader.reload()
      assert DevReloader.status().generation == 0
    end
  end
end
