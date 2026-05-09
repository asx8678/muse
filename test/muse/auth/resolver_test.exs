defmodule Muse.Auth.ResolverTest do
  use ExUnit.Case, async: true

  alias Muse.Auth.{Credential, Resolver}

  describe "resolve/2" do
    test ":none returns no credential" do
      assert Resolver.resolve(%{auth: :none}) == :none
      assert Resolver.resolve(%{"auth" => "none"}) == :none
    end

    test "missing auth mode defaults to no credential" do
      assert Resolver.resolve(%{}) == :none
    end

    test "api_key resolves from injected env map and redacts inspect output" do
      assert {:ok, %Credential{} = credential} =
               Resolver.resolve(
                 %{auth: :api_key, env_key: "MUSE_TEST_API_KEY"},
                 env: %{"MUSE_TEST_API_KEY" => "sk-resolver-secret"},
                 system_env?: false
               )

      assert credential.type == :api_key
      assert credential.source == :env
      assert credential.value == "sk-resolver-secret"
      assert credential.redacted =~ "REDACTED"

      inspected = inspect(credential)
      assert inspected =~ "REDACTED"
      refute inspected =~ "sk-resolver-secret"
    end

    test "bearer_command resolves through injected runner without shelling out" do
      runner = fn "print-token" -> {:ok, "tok-runner-secret\n"} end

      assert {:ok, %Credential{} = credential} =
               Resolver.resolve(%{
                 auth: :bearer_command,
                 bearer_command: "print-token",
                 auth_runner: runner
               })

      assert credential.type == :bearer
      assert credential.source == :command
      # source_ref is not set by BearerCommand (it defaults to nil)
      # The old resolver runner path set source_ref, but BearerCommand doesn't
      assert credential.value == "tok-runner-secret"
      refute inspect(credential) =~ "tok-runner-secret"
    end

    test "bearer_command auth_runner respects max_stdout_bytes via BearerCommand" do
      # Injected runner returning oversized output should fail with output_too_large
      # because the resolver now routes through BearerCommand.resolve/1
      huge = String.duplicate("x", 5000)
      runner = fn _cmd -> {huge, 0} end

      assert {:error, {:output_too_large, "bearer_command"}} =
               Resolver.resolve(%{
                 auth: :bearer_command,
                 bearer_command: "ignored",
                 auth_runner: runner,
                 max_stdout_bytes: 100
               })
    end

    test "bearer_command auth_runner validates token shape" do
      # Non-printable output should fail through BearerCommand validation
      runner = fn _cmd -> {"tok\x00bad", 0} end

      assert {:error, {:exec_failed, _msg}} =
               Resolver.resolve(%{
                 auth: :bearer_command,
                 bearer_command: "ignored",
                 auth_runner: runner
               })
    end

    test "bearer_command auth_runner supports prior two-arity runner contract" do
      runner = fn "ignored", opts ->
        assert opts[:source_label] == "bearer_command"
        {:ok, "tok-runner-two-arity"}
      end

      assert {:ok, credential} =
               Resolver.resolve(%{
                 auth: :bearer_command,
                 bearer_command: "ignored",
                 auth_runner: runner
               })

      assert credential.value == "tok-runner-two-arity"
    end

    test "bearer_command passes timeout_ms through to BearerCommand" do
      runner = fn _cmd ->
        :timer.sleep(100)
        {:ok, "too-late"}
      end

      assert {:error, {:timeout, "bearer_command"}} =
               Resolver.resolve(%{
                 auth: :bearer_command,
                 bearer_command: "ignored",
                 auth_runner: runner,
                 timeout_ms: 10
               })
    end

    test "codex_cache resolves from temp JSON and carries permission warning" do
      path = tmp_path("codex_auth.json")
      File.write!(path, Jason.encode!(%{"access_token" => "tok-codex-secret"}))
      File.chmod!(path, 0o644)

      assert {:ok, %Credential{} = credential} =
               Resolver.resolve(%{auth: :codex_cache, codex_cache_path: path})

      assert credential.type == :bearer
      assert credential.source == :codex_cache
      assert credential.value == "tok-codex-secret"
      assert {:permissive_permissions, "0600 recommended"} in credential.warnings
      refute inspect(credential) =~ "tok-codex-secret"
    after
      path = tmp_path("codex_auth.json")
      File.rm(path)
    end

    test "openai_oauth returns clear unsupported error" do
      assert {:error,
              {:unsupported_auth_mode, :openai_oauth, "OpenAI OAuth auth is not supported yet"}} =
               Resolver.resolve(%{auth: :openai_oauth})
    end

    test "unsupported auth mode errors without leaking raw token-like values" do
      assert {:error, {:unsupported_auth_mode, mode}} =
               Resolver.resolve(%{auth: "Bearer sk-unsupported-secret"})

      rendered = inspect(mode)
      refute rendered =~ "sk-unsupported-secret"
      refute rendered =~ "Bearer sk"
    end
  end

  defp tmp_path(filename) do
    dir = Path.join(System.tmp_dir!(), "muse-auth-resolver-test")
    File.mkdir_p!(dir)
    Path.join(dir, filename)
  end
end
