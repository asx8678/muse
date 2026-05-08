defmodule Muse.Telemetry.ExportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Muse.Telemetry
  alias Muse.Telemetry.Export

  setup do
    # Ensure any previous handler is detached between tests
    Export.detach()
    on_exit(fn -> Export.detach() end)
    :ok
  end

  # -- Attachment / detachment --------------------------------------------------

  describe "attach/2 — stdout mode" do
    test "attaches handler for all telemetry events" do
      _output =
        capture_io(fn ->
          assert :ok = Export.attach(:stdout)

          :telemetry.execute(
            Telemetry.turn_start(),
            %{},
            Telemetry.turn_start_metadata(session_id: "s", turn_id: "t")
          )

          Export.detach()
        end)
    end

    test "is idempotent (reattaching works)" do
      _output =
        capture_io(fn ->
          assert :ok = Export.attach(:stdout)
          assert :ok = Export.attach(:stdout)
          Export.detach()
        end)
    end
  end

  describe "attach/2 — file mode" do
    test "requires path option" do
      assert {:error, :missing_file_path} = Export.attach(:file, [])
    end

    test "rejects empty path" do
      assert {:error, :missing_file_path} = Export.attach(:file, path: "")
    end

    test "attaches and writes JSONL events" do
      path =
        Path.join(
          System.tmp_dir!(),
          "muse_telemetry_export_#{System.unique_integer([:positive])}.jsonl"
        )

      try do
        assert :ok = Export.attach(:file, path: path)

        :telemetry.execute(
          Telemetry.turn_start(),
          %{},
          Telemetry.turn_start_metadata(session_id: "sess_1", turn_id: "turn_1")
        )

        # Give file I/O a moment
        Process.sleep(50)

        assert File.exists?(path)
        lines = File.read!(path) |> String.split("\n", trim: true)
        assert length(lines) >= 1

        line = hd(lines)
        assert {:ok, decoded} = Jason.decode(line)
        assert decoded["event"] == "muse.turn.start"
        assert is_map(decoded["metadata"])
        assert is_map(decoded["measurements"])
      after
        File.rm(path)
      end
    end
  end

  describe "attach/2 — pluggable MFA mode" do
    test "attaches and calls the provided function" do
      test_pid = self()

      _handler_fn = fn envelope ->
        send(test_pid, {:exported, envelope})
      end

      assert :ok = Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      :telemetry.execute(
        Telemetry.turn_stop(),
        Telemetry.turn_stop_measurements(100),
        Telemetry.turn_stop_metadata(session_id: "s", turn_id: "t", status: :completed)
      )

      assert_receive {:exported, envelope}
      assert envelope["event"] == "muse.turn.stop"
      # Metadata has atom keys after sanitize; access via atom or string key
      meta = envelope["metadata"]
      assert meta[:session_id] == "s" or meta["session_id"] == "s"
      assert is_map(envelope["measurements"])
    end

    def pluggable_handler(envelope, test_pid) do
      send(test_pid, {:exported, envelope})
    end
  end

  describe "attach/2 — invalid modes" do
    test "rejects unknown mode atom" do
      assert {:error, :invalid_mode} = Export.attach(:webhook)
    end
  end

  describe "attach_from_env/0" do
    test "does not attach when env is off (default)" do
      # Clear env to default
      original = System.get_env("MUSE_TELEMETRY_EXPORT")
      System.delete_env("MUSE_TELEMETRY_EXPORT")

      try do
        assert :ok = Export.attach_from_env()
        # Emitting should not crash
        :telemetry.execute(Telemetry.turn_start(), %{}, %{session_id: "s"})
      after
        if original,
          do: System.put_env("MUSE_TELEMETRY_EXPORT", original),
          else: System.delete_env("MUSE_TELEMETRY_EXPORT")
      end
    end

    test "attaches stdout mode from env" do
      original = System.get_env("MUSE_TELEMETRY_EXPORT")
      System.put_env("MUSE_TELEMETRY_EXPORT", "stdout")

      try do
        assert :ok = Export.attach_from_env()
      after
        Export.detach()

        if original,
          do: System.put_env("MUSE_TELEMETRY_EXPORT", original),
          else: System.delete_env("MUSE_TELEMETRY_EXPORT")
      end
    end

    test "returns error when file mode requested without MUSE_TELEMETRY_FILE" do
      original_export = System.get_env("MUSE_TELEMETRY_EXPORT")
      original_file = System.get_env("MUSE_TELEMETRY_FILE")
      System.put_env("MUSE_TELEMETRY_EXPORT", "file")
      System.delete_env("MUSE_TELEMETRY_FILE")

      try do
        assert {:error, :missing_file_path} = Export.attach_from_env()
      after
        if original_export,
          do: System.put_env("MUSE_TELEMETRY_EXPORT", original_export),
          else: System.delete_env("MUSE_TELEMETRY_EXPORT")

        if original_file,
          do: System.put_env("MUSE_TELEMETRY_FILE", original_file),
          else: System.delete_env("MUSE_TELEMETRY_FILE")
      end
    end

    test "ignores unknown env values (no crash)" do
      original = System.get_env("MUSE_TELEMETRY_EXPORT")
      System.put_env("MUSE_TELEMETRY_EXPORT", "kafka")

      try do
        assert :ok = Export.attach_from_env()
      after
        if original,
          do: System.put_env("MUSE_TELEMETRY_EXPORT", original),
          else: System.delete_env("MUSE_TELEMETRY_EXPORT")
      end
    end
  end

  describe "detach/0" do
    test "is idempotent" do
      assert :ok = Export.detach()
      assert :ok = Export.detach()
    end

    test "detaches previously attached handler" do
      test_pid = self()

      assert :ok = Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      # Should receive event
      :telemetry.execute(
        Telemetry.turn_start(),
        %{},
        Telemetry.turn_start_metadata(session_id: "s1", turn_id: "t1")
      )

      assert_receive {:exported, _}

      Export.detach()

      # Should NOT receive after detach
      :telemetry.execute(
        Telemetry.turn_start(),
        %{},
        Telemetry.turn_start_metadata(session_id: "s2", turn_id: "t2")
      )

      refute_receive {:exported, _}, 100
    end
  end

  # -- Secret redaction in exported envelopes ------------------------------------

  describe "secret redaction — defense in depth" do
    test "stdout export redacts API keys in metadata values" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Export.attach(:stdout)

          # Emit with a secret embedded in a string value — the metadata
          # helper already sanitizes, but test the defense-in-depth layer.
          :telemetry.execute(
            Telemetry.turn_exception(),
            %{},
            Telemetry.turn_exception_metadata(
              session_id: "s",
              turn_id: "t",
              kind: :error,
              reason: "API key sk-test-secret-key-99999 was rejected"
            )
          )

          Export.detach()
        end)

      refute output =~ "sk-test-secret-key-99999",
             "Secret leaked in stdout export output"
    end

    test "file export redacts API keys in written JSONL" do
      path =
        Path.join(
          System.tmp_dir!(),
          "muse_redact_test_#{System.unique_integer([:positive])}.jsonl"
        )

      try do
        Export.attach(:file, path: path)

        :telemetry.execute(
          Telemetry.turn_exception(),
          %{},
          Telemetry.turn_exception_metadata(
            session_id: "s",
            turn_id: "t",
            kind: :error,
            reason: "Bearer sk-proj-LEAKED-KEY in reason"
          )
        )

        Process.sleep(50)
        content = File.read!(path)

        refute content =~ "sk-proj-LEAKED-KEY",
               "Secret leaked in file export output"
      after
        Export.detach()
        File.rm(path)
      end
    end

    test "pluggable export receives redacted metadata" do
      test_pid = self()

      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      :telemetry.execute(
        Telemetry.turn_exception(),
        %{},
        Telemetry.turn_exception_metadata(
          session_id: "s",
          turn_id: "t",
          kind: :error,
          reason: "Connection failed: token=sk-test-redact-me-12345"
        )
      )

      assert_receive {:exported, envelope}
      metadata_str = inspect(envelope["metadata"])

      refute metadata_str =~ "sk-test-redact-me-12345",
             "Secret leaked in pluggable export metadata"
    end

    test "raw secret in unsanitized metadata is caught by defense-in-depth" do
      test_pid = self()

      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      # Emit with raw metadata that bypasses the Telemetry helper —
      # this simulates a bug where metadata is passed directly.
      :telemetry.execute(
        Telemetry.turn_start(),
        %{},
        %{session_id: "s", detail: "api_key=sk-test-RAW-SECRET-12345"}
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "sk-test-RAW-SECRET-12345",
             "Raw secret leaked through defense-in-depth export layer"
    end

    test "bearer tokens are redacted in export" do
      test_pid = self()

      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      :telemetry.execute(
        Telemetry.turn_exception(),
        %{},
        Telemetry.turn_exception_metadata(
          session_id: "s",
          turn_id: "t",
          kind: :error,
          reason: "Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.sig"
        )
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "eyJhbGciOiJSUzI1NiJ9",
             "JWT leaked in export output"
    end

    test "raw secret in measurement string value is redacted" do
      test_pid = self()

      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      # Simulate a bug: measurements with a raw secret string value
      :telemetry.execute(
        Telemetry.turn_stop(),
        %{duration_ms: 100, detail: "key=sk-test-MEAS-SECRET-999"},
        Telemetry.turn_stop_metadata(session_id: "s", turn_id: "t", status: :ok)
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "sk-test-MEAS-SECRET-999",
             "Secret leaked in measurement value"
    end

    test "raw secret in nested measurement map value is redacted" do
      test_pid = self()

      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      # Simulate a bug: measurements with a nested map containing a secret
      :telemetry.execute(
        Telemetry.turn_stop(),
        %{duration_ms: 100, extra: %{note: "Bearer sk-proj-NESTED-KEY"}},
        Telemetry.turn_stop_metadata(session_id: "s", turn_id: "t", status: :ok)
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "sk-proj-NESTED-KEY",
             "Secret leaked in nested measurement value"
    end

    test "raw secret in measurement list value is redacted" do
      test_pid = self()

      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      # Simulate a bug: measurements with a list containing a secret string
      :telemetry.execute(
        Telemetry.turn_stop(),
        %{duration_ms: 100, tags: ["api_key=sk-test-LIST-LEAK"]},
        Telemetry.turn_stop_metadata(session_id: "s", turn_id: "t", status: :ok)
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "sk-test-LIST-LEAK",
             "Secret leaked in measurement list value"
    end

    # -- Prompt-specific patterns: DATABASE_URL, private keys, URL credentials ---

    test "DATABASE_URL in metadata is redacted" do
      test_pid = self()
      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      :telemetry.execute(
        Telemetry.turn_exception(),
        %{},
        Telemetry.turn_exception_metadata(
          session_id: "s",
          turn_id: "t",
          kind: :error,
          reason: "env DATABASE_URL=postgres://admin:s3cret@db.example.com:5432/prod"
        )
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "s3cret@db.example.com",
             "DATABASE_URL credentials leaked in export"

      assert envelope_str =~ "[REDACTED]"
    end

    test "private key block in metadata is redacted" do
      test_pid = self()
      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      private_key =
        "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIABAKBgQC7VJTUt9Us8cKjMqESh8fC0" <>
          "reallylongkeydata\n-----END RSA PRIVATE KEY-----"

      :telemetry.execute(
        Telemetry.turn_exception(),
        %{},
        Telemetry.turn_exception_metadata(
          session_id: "s",
          turn_id: "t",
          kind: :error,
          reason: "loaded key: #{private_key}"
        )
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "MIIEowIABAKBgQC7VJTUt9Us8cKjMqESh8fC0",
             "Private key block leaked in export"

      assert envelope_str =~ "[REDACTED]"
    end

    test "URL-embedded credentials in metadata are redacted" do
      test_pid = self()
      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      :telemetry.execute(
        Telemetry.turn_exception(),
        %{},
        Telemetry.turn_exception_metadata(
          session_id: "s",
          turn_id: "t",
          kind: :error,
          reason: "connecting to https://admin:hunter2@internal.corp/api"
        )
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "admin:hunter2@internal.corp",
             "URL-embedded credentials leaked in export"
    end

    test "DATABASE_URL in measurements is redacted" do
      test_pid = self()
      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      :telemetry.execute(
        Telemetry.turn_stop(),
        %{duration_ms: 100, env: "DATABASE_URL=postgres://u:p@host/db"},
        Telemetry.turn_stop_metadata(session_id: "s", turn_id: "t", status: :ok)
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "p@host/db",
             "DATABASE_URL leaked in measurement value"
    end

    test "private key in measurements is redacted" do
      test_pid = self()
      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      pk =
        "-----BEGIN PRIVATE KEY-----\nABCDEF123456\n-----END PRIVATE KEY-----"

      :telemetry.execute(
        Telemetry.turn_stop(),
        %{duration_ms: 100, key_data: pk},
        Telemetry.turn_stop_metadata(session_id: "s", turn_id: "t", status: :ok)
      )

      assert_receive {:exported, envelope}
      envelope_str = inspect(envelope)

      refute envelope_str =~ "ABCDEF123456",
             "Private key leaked in measurement value"

      assert envelope_str =~ "[REDACTED]"
    end
  end

  # -- Envelope structure -------------------------------------------------------

  describe "envelope structure" do
    test "envelope has required fields" do
      test_pid = self()
      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      :telemetry.execute(
        Telemetry.session_created(),
        %{},
        Telemetry.session_created_metadata(session_id: "s1", workspace: "/tmp")
      )

      assert_receive {:exported, envelope}
      assert is_binary(envelope["event"])
      assert is_binary(envelope["timestamp"])
      assert is_map(envelope["measurements"])
      assert is_map(envelope["metadata"])
    end

    test "event name uses dot-separated string format" do
      test_pid = self()
      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      :telemetry.execute(
        Telemetry.session_ended(),
        Telemetry.session_ended_measurements(1000),
        Telemetry.session_ended_metadata(session_id: "s1", status: :shutdown)
      )

      assert_receive {:exported, envelope}
      assert envelope["event"] == "muse.session.ended"
    end

    test "measurements are present in envelope" do
      test_pid = self()
      Export.attach({:mfa, __MODULE__, :pluggable_handler, [test_pid]})

      :telemetry.execute(
        Telemetry.session_ended(),
        Telemetry.session_ended_measurements(5000),
        Telemetry.session_ended_metadata(session_id: "s1", status: :shutdown)
      )

      assert_receive {:exported, envelope}
      measures = envelope["measurements"]
      assert measures[:duration_ms] == 5000 or measures["duration_ms"] == 5000
    end
  end

  # -- Handler crash safety -----------------------------------------------------

  describe "handler crash safety" do
    test "crashing pluggable handler does not crash the caller" do
      Export.attach({:mfa, __MODULE__, :crashing_handler, []})

      # This should NOT raise even though the handler crashes
      :telemetry.execute(
        Telemetry.turn_start(),
        %{},
        Telemetry.turn_start_metadata(session_id: "s", turn_id: "t")
      )

      # If we reach here, the handler didn't crash the caller
      assert true
    end

    def crashing_handler(_envelope) do
      raise "intentional crash"
    end

    test "handler that throws does not crash the caller" do
      Export.attach({:mfa, __MODULE__, :throwing_handler, []})

      :telemetry.execute(
        Telemetry.turn_start(),
        %{},
        Telemetry.turn_start_metadata(session_id: "s", turn_id: "t")
      )

      assert true
    end

    def throwing_handler(_envelope) do
      throw(:boom)
    end

    test "handler that exits does not crash the caller" do
      Export.attach({:mfa, __MODULE__, :exiting_handler, []})

      :telemetry.execute(
        Telemetry.turn_start(),
        %{},
        Telemetry.turn_start_metadata(session_id: "s", turn_id: "t")
      )

      assert true
    end

    def exiting_handler(_envelope) do
      exit(:bye)
    end

    test "handler survives after a failure — second event still delivered" do
      test_pid = self()

      # Use a handler that fails on first call but succeeds on second
      Export.attach({:mfa, __MODULE__, :fail_once_handler, [test_pid, :fail_once_ref]})

      # First event: handler raises, should be caught by export handler
      :telemetry.execute(
        Telemetry.turn_start(),
        %{},
        Telemetry.turn_start_metadata(session_id: "s1", turn_id: "t1")
      )

      # Second event: handler should succeed (fail_once_ref already used)
      :telemetry.execute(
        Telemetry.turn_stop(),
        Telemetry.turn_stop_measurements(100),
        Telemetry.turn_stop_metadata(session_id: "s2", turn_id: "t2", status: :completed)
      )

      assert_receive {:exported_ok, envelope}
      assert envelope["event"] == "muse.turn.stop"
    end

    def fail_once_handler(envelope, test_pid, ref) do
      if Process.get(ref) do
        send(test_pid, {:exported_ok, envelope})
      else
        Process.put(ref, true)
        raise "first call failure"
      end
    end

    test "handler is NOT detached by :telemetry after a failure" do
      test_pid = self()

      # Attach a handler that crashes first then succeeds
      Export.attach({:mfa, __MODULE__, :fail_once_handler, [test_pid, :persist_check_ref]})

      # First event: handler raises, export handler catches it
      :telemetry.execute(
        Telemetry.turn_start(),
        %{},
        Telemetry.turn_start_metadata(session_id: "s1", turn_id: "t1")
      )

      # Second event: handler should still be attached and succeed
      :telemetry.execute(
        Telemetry.turn_stop(),
        Telemetry.turn_stop_measurements(100),
        Telemetry.turn_stop_metadata(session_id: "s2", turn_id: "t2", status: :completed)
      )

      # If the handler was detached, we would never receive this message
      assert_receive {:exported_ok, envelope}
      assert envelope["event"] == "muse.turn.stop"
    end
  end
end
