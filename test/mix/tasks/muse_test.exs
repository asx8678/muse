defmodule Mix.Tasks.MuseTest do
  use ExUnit.Case, async: false

  # We toggle app env, so async: false

  setup do
    original_boot_args = Application.get_env(:muse, :boot_args)
    original_source_mode = Application.get_env(:muse, :source_mode?)

    on_exit(fn ->
      if original_boot_args do
        Application.put_env(:muse, :boot_args, original_boot_args)
      else
        Application.delete_env(:muse, :boot_args)
      end

      if original_source_mode != nil do
        Application.put_env(:muse, :source_mode?, original_source_mode)
      else
        Application.delete_env(:muse, :source_mode?)
      end
    end)

    :ok
  end

  describe "Mix.Tasks.Muse.run/1 delegates to boot/3" do
    test "sets source_mode? to true via boot" do
      # We can't call run/1 directly (it sleeps forever), so test the
      # delegation by calling boot/3 with the same args the Mix task would.
      Application.stop(:muse)

      Muse.CLI.Main.boot(["--no-web"], true, noop_sleep())

      assert Application.get_env(:muse, :source_mode?) == true
      assert Application.get_env(:muse, :boot_args) == ["--no-web"]

      Application.ensure_all_started(:muse)
    end

    test "stores args correctly in source mode" do
      Application.stop(:muse)

      args = ["--workspace", "/tmp/mix-test", "--port", "4100"]
      Muse.CLI.Main.boot(args, true, noop_sleep())

      assert Application.get_env(:muse, :boot_args) == args
      assert Application.get_env(:muse, :source_mode?) == true

      Application.ensure_all_started(:muse)
    end
  end

  describe "@shortdoc" do
    test "mix task has a shortdoc" do
      assert Mix.Tasks.Muse.__info__(:attributes)[:shortdoc] != nil
    end
  end

  describe "run/1 can be exercised in a spawned process" do
    test "spawned run sets env and then sleeps" do
      Application.stop(:muse)

      # Spawn the task in a separate process; after a short delay kill it.
      parent = self()
      ref = make_ref()

      pid =
        spawn(fn ->
          try do
            Mix.Tasks.Muse.run(["--no-web"])
          catch
            :exit, _ -> send(parent, {:done, ref})
          end
        end)

      # Give it time to set env and enter sleep
      Process.sleep(100)
      Process.exit(pid, :kill)

      # The catch may not fire if we killed before trap, so just check env
      assert Application.get_env(:muse, :boot_args) == ["--no-web"]
      assert Application.get_env(:muse, :source_mode?) == true

      Application.ensure_all_started(:muse)
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp noop_sleep, do: fn :infinity -> :ok end
end
