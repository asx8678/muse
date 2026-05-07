defmodule Muse.Execution.TargetRegistryTest do
  use ExUnit.Case, async: false

  alias Muse.Execution.{Target, TargetRegistry}

  # TargetRegistry is started by base_children/0 in the application supervisor.
  # We just interact with it and clean up after each test.

  setup do
    on_exit(fn ->
      TargetRegistry.clear()
    end)

    :ok
  end

  describe "register/1" do
    test "registers a target" do
      {:ok, target} = Target.new("tgt_test_1", protocol: :fake, host: "host.io")
      assert :ok = TargetRegistry.register(target)
    end

    test "can fetch a registered target" do
      {:ok, target} =
        Target.new("tgt_fetch", protocol: :fake, host: "host.io", label: "Test Target")

      :ok = TargetRegistry.register(target)

      assert {:ok, fetched} = TargetRegistry.fetch("tgt_fetch")
      assert fetched.id == "tgt_fetch"
      assert fetched.protocol == :fake
      assert fetched.label == "Test Target"
    end

    test "overwrites existing target with same id" do
      {:ok, t1} = Target.new("tgt_dup", protocol: :fake, host: "host1.io")
      :ok = TargetRegistry.register(t1)

      {:ok, t2} = Target.new("tgt_dup", protocol: :fake, host: "host2.io")
      :ok = TargetRegistry.register(t2)

      assert {:ok, fetched} = TargetRegistry.fetch("tgt_dup")
      assert fetched.host == "host2.io"
    end
  end

  describe "fetch/1" do
    test "returns not_found for missing target" do
      assert {:error, :not_found} = TargetRegistry.fetch("nonexistent")
    end
  end

  describe "get!/1" do
    test "returns target when found" do
      {:ok, target} = Target.new("tgt_get", protocol: :fake, host: "host.io")
      :ok = TargetRegistry.register(target)

      assert %Target{} = TargetRegistry.get!("tgt_get")
    end

    test "raises when not found" do
      assert_raise ArgumentError, ~r/target not found/, fn ->
        TargetRegistry.get!("nonexistent")
      end
    end
  end

  describe "list/0" do
    test "returns empty list when no targets registered" do
      # Clear to ensure clean state
      TargetRegistry.clear()
      assert [] = TargetRegistry.list()
    end

    test "returns all registered targets" do
      {:ok, t1} = Target.new("tgt_list_1", protocol: :fake, host: "host1.io")
      {:ok, t2} = Target.new("tgt_list_2", protocol: :fake, host: "host2.io")
      :ok = TargetRegistry.register(t1)
      :ok = TargetRegistry.register(t2)

      targets = TargetRegistry.list()
      ids = Enum.map(targets, & &1.id)
      assert "tgt_list_1" in ids
      assert "tgt_list_2" in ids
    end
  end

  describe "update/1" do
    test "updates an existing target" do
      {:ok, target} = Target.new("tgt_update", protocol: :fake, host: "original.io")
      :ok = TargetRegistry.register(target)

      {:ok, updated} = Target.new("tgt_update", protocol: :fake, host: "updated.io")
      assert :ok = TargetRegistry.update(updated)

      assert {:ok, fetched} = TargetRegistry.fetch("tgt_update")
      assert fetched.host == "updated.io"
    end

    test "returns not_found for non-existent target" do
      {:ok, target} = Target.new("tgt_noexist", protocol: :fake, host: "host.io")
      assert {:error, :not_found} = TargetRegistry.update(target)
    end

    test "sets updated_at timestamp on update" do
      {:ok, target} = Target.new("tgt_ts", protocol: :fake, host: "original.io")
      :ok = TargetRegistry.register(target)

      Process.sleep(10)

      {:ok, updated} = Target.new("tgt_ts", protocol: :fake, host: "updated.io")
      :ok = TargetRegistry.update(updated)

      assert {:ok, fetched} = TargetRegistry.fetch("tgt_ts")
      # Updated_at should be set by the registry
      assert fetched.updated_at != nil
    end
  end

  describe "remove/1" do
    test "removes a target" do
      {:ok, target} = Target.new("tgt_remove", protocol: :fake, host: "host.io")
      :ok = TargetRegistry.register(target)
      assert :ok = TargetRegistry.remove("tgt_remove")
      assert {:error, :not_found} = TargetRegistry.fetch("tgt_remove")
    end

    test "returns not_found for non-existent target" do
      assert {:error, :not_found} = TargetRegistry.remove("nonexistent")
    end
  end

  describe "clear/0" do
    test "clears all targets" do
      {:ok, t1} = Target.new("tgt_clear_1", protocol: :fake, host: "host1.io")
      {:ok, t2} = Target.new("tgt_clear_2", protocol: :fake, host: "host2.io")
      :ok = TargetRegistry.register(t1)
      :ok = TargetRegistry.register(t2)

      assert :ok = TargetRegistry.clear()
      assert [] = TargetRegistry.list()
    end
  end

  describe "event emission" do
    setup do
      # Start Muse.State for event capture (it may already be running)
      case GenServer.whereis(Muse.State) do
        nil ->
          # Start PubSub first if needed
          case GenServer.whereis(Muse.PubSub) do
            nil -> start_supervised!({Phoenix.PubSub, name: Muse.PubSub})
            _ -> :ok
          end

          start_supervised!(Muse.State)

        _pid ->
          :ok
      end

      :ok
    end

    test "emits :target_registered event on register" do
      Muse.State.subscribe()

      {:ok, target} = Target.new("tgt_event_reg", protocol: :fake, host: "host.io")
      :ok = TargetRegistry.register(target)

      assert_receive {:muse_event, event}, 500
      assert event.type == :target_registered
      assert event.data.id == "tgt_event_reg"
      assert event.data.protocol == :fake
    end

    test "emits :target_updated event on update" do
      {:ok, target} = Target.new("tgt_event_upd", protocol: :fake, host: "original.io")
      :ok = TargetRegistry.register(target)

      Muse.State.subscribe()

      {:ok, updated} = Target.new("tgt_event_upd", protocol: :fake, host: "updated.io")
      :ok = TargetRegistry.update(updated)

      assert_receive {:muse_event, event}, 500
      assert event.type == :target_updated
      assert event.data.id == "tgt_event_upd"
    end

    test "emits :target_removed event on remove" do
      {:ok, target} = Target.new("tgt_event_rem", protocol: :fake, host: "host.io")
      :ok = TargetRegistry.register(target)

      Muse.State.subscribe()

      :ok = TargetRegistry.remove("tgt_event_rem")

      assert_receive {:muse_event, event}, 500
      assert event.type == :target_removed
      assert event.data.id == "tgt_event_rem"
    end

    test "events never contain user field" do
      Muse.State.subscribe()

      {:ok, target} =
        Target.new("tgt_no_user", protocol: :fake, host: "host.io", user: "secret_user")

      :ok = TargetRegistry.register(target)

      assert_receive {:muse_event, event}, 500
      refute Map.has_key?(event.data, :user)
    end

    test "events never contain credential_ref field" do
      Muse.State.subscribe()

      {:ok, target} =
        Target.new("tgt_no_cred",
          protocol: :fake,
          host: "host.io",
          credential_ref: {:secret, "key"}
        )

      :ok = TargetRegistry.register(target)

      assert_receive {:muse_event, event}, 500
      refute Map.has_key?(event.data, :credential_ref)
    end

    test "events never contain connection_opts field" do
      Muse.State.subscribe()

      {:ok, target} =
        Target.new("tgt_no_opts",
          protocol: :fake,
          host: "host.io",
          connection_opts: [password: "secret123"]
        )

      :ok = TargetRegistry.register(target)

      assert_receive {:muse_event, event}, 500
      refute Map.has_key?(event.data, :connection_opts)
    end

    test "events use :internal visibility" do
      Muse.State.subscribe()

      {:ok, target} = Target.new("tgt_vis", protocol: :fake, host: "host.io")
      :ok = TargetRegistry.register(target)

      assert_receive {:muse_event, event}, 500
      assert event.visibility == :internal
    end
  end

  describe "safety: no credentials in registry data" do
    test "fetch returns target with user/credential_ref but events don't" do
      {:ok, target} =
        Target.new("tgt_cred_test",
          protocol: :fake,
          host: "host.io",
          user: "secret_user",
          credential_ref: {:ref, "secret_key"},
          connection_opts: [password: "secret123"]
        )

      :ok = TargetRegistry.register(target)

      # Fetch returns the full target (server-side usage is allowed to see credentials)
      assert {:ok, %Target{user: "secret_user"}} = TargetRegistry.fetch("tgt_cred_test")

      # But safe_payload excludes them
      assert {:ok, fetched} = TargetRegistry.fetch("tgt_cred_test")
      payload = Target.safe_payload(fetched)
      refute Map.has_key?(payload, :user)
      refute Map.has_key?(payload, :credential_ref)
      refute Map.has_key?(payload, :connection_opts)
    end
  end

  # -- ETS protection -----------------------------------------------------------

  describe "ETS table protection" do
    test "direct ETS insert from caller process is denied (protected table)" do
      # The ETS table is :protected, so only the owning GenServer can write.
      # A direct :ets.insert from a test process should raise.
      assert_raise ArgumentError, fn ->
        :ets.insert(TargetRegistry, {"hijacked", "malicious"})
      end
    end

    test "direct ETS delete from caller process is denied (protected table)" do
      {:ok, target} = Target.new("tgt_protected", protocol: :fake, host: "host.io")
      :ok = TargetRegistry.register(target)

      # Direct delete from non-owner process should raise
      assert_raise ArgumentError, fn ->
        :ets.delete(TargetRegistry, "tgt_protected")
      end

      # Target should still be present (write was denied)
      assert {:ok, _} = TargetRegistry.fetch("tgt_protected")
    end

    test "reads from caller process succeed (protected table allows reads)" do
      {:ok, target} = Target.new("tgt_read_test", protocol: :fake, host: "host.io")
      :ok = TargetRegistry.register(target)

      # Direct read should work — :protected allows non-owner reads
      [{"tgt_read_test", %Target{}}] = :ets.lookup(TargetRegistry, "tgt_read_test")
    end
  end

  # -- get/1 --------------------------------------------------------------------

  describe "get/1" do
    test "returns target when found" do
      {:ok, target} = Target.new("tgt_get_nil", protocol: :fake, host: "host.io")
      :ok = TargetRegistry.register(target)

      assert %Target{} = TargetRegistry.get("tgt_get_nil")
    end

    test "returns nil when not found" do
      assert nil == TargetRegistry.get("nonexistent")
    end
  end

  # -- Registry events redact secret-like values -------------------------------

  describe "registry events redact secret-like values" do
    setup do
      case GenServer.whereis(Muse.State) do
        nil ->
          case GenServer.whereis(Muse.PubSub) do
            nil -> start_supervised!({Phoenix.PubSub, name: Muse.PubSub})
            _ -> :ok
          end

          start_supervised!(Muse.State)

        _pid ->
          :ok
      end

      :ok
    end

    test "events redact secret-like id/label/host/tag values" do
      Muse.State.subscribe()

      {:ok, target} =
        Target.new("tgt_event_redact",
          protocol: :fake,
          host: "staging.example.com",
          label: "DATABASE_URL=postgres://user:pass@host/db",
          tags: ["web", "sk-test-secret-key-1234567890abcdef1234567890"],
          user: "secret_user",
          credential_ref: {:ref, "secret_key"},
          connection_opts: [password: "secret123"]
        )

      :ok = TargetRegistry.register(target)

      assert_receive {:muse_event, event}, 500

      # Event data should have secret patterns redacted (via safe_payload + redact_term)
      refute event.data.label =~ "postgres://user:pass@host/db"
      assert event.data.label =~ "[REDACTED]"

      secret_tag = Enum.find(event.data.tags, &String.contains?(&1, "sk-test-secret-key"))
      assert secret_tag == nil

      # Never include user/credential_ref/connection_opts
      refute Map.has_key?(event.data, :user)
      refute Map.has_key?(event.data, :credential_ref)
      refute Map.has_key?(event.data, :connection_opts)
    end
  end
end
