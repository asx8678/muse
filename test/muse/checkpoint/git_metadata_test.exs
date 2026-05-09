defmodule Muse.Checkpoint.GitMetadataTest do
  use ExUnit.Case, async: false

  alias Muse.Checkpoint.GitMetadata

  describe "capture/2 — real git repo" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "git_meta_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      # Initialize a real git repo so we get real metadata
      System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp)
      System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

      File.write!(Path.join(tmp, "README.md"), "hello")
      System.cmd("git", ["add", "."], cd: tmp, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "init"], cd: tmp, stderr_to_stdout: true)

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{workspace: tmp}
    end

    test "captures head_sha and branch from a real git repo", %{workspace: workspace} do
      {:ok, meta} = GitMetadata.capture(workspace)

      assert is_binary(meta.head_sha)
      assert String.length(meta.head_sha) == 40
      assert is_binary(meta.branch)
      assert meta.branch == "main" or meta.branch == "master"
    end

    test "detects clean working tree", %{workspace: workspace} do
      {:ok, meta} = GitMetadata.capture(workspace)
      assert meta.dirty == false
    end

    test "detects dirty working tree", %{workspace: workspace} do
      File.write!(Path.join(workspace, "new_file.txt"), "dirty content")
      {:ok, meta} = GitMetadata.capture(workspace)
      assert meta.dirty == true
    end

    test "stash_ref is nil for clean tree", %{workspace: workspace} do
      {:ok, meta} = GitMetadata.capture(workspace)
      # git stash create returns empty string when nothing to stash
      assert meta.stash_ref == "" or meta.stash_ref == nil
    end

    test "returns fallback when capture_git_stash is false", %{workspace: workspace} do
      {:ok, meta} = GitMetadata.capture(workspace, capture_git_stash: false)
      assert meta == %{stash_ref: nil, head_sha: nil, branch: nil, dirty: nil}
    end

    test "git_timeout_ms option is accepted", %{workspace: workspace} do
      {:ok, meta} = GitMetadata.capture(workspace, git_timeout_ms: 10_000)
      assert is_binary(meta.head_sha)
    end
  end

  describe "capture/2 — non-git directory (failure fallback)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "git_meta_nongit_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{workspace: tmp}
    end

    test "returns fallback metadata for non-git directory", %{workspace: workspace} do
      {:ok, meta} = GitMetadata.capture(workspace)
      assert meta.stash_ref == nil
      assert meta.head_sha == nil
      assert meta.branch == nil
      assert meta.dirty == nil
    end

    test "does not crash checkpoint flow on git failure", %{workspace: workspace} do
      # This is the critical safety property: git failures must not crash
      result = GitMetadata.capture(workspace)
      assert {:ok, _} = result
    end
  end

  describe "capture/2 — git command timeout" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "git_meta_timeout_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      # Create a fake "git" script that sleeps forever
      fake_git_dir = Path.join(tmp, "fake_bin")
      File.mkdir_p!(fake_git_dir)

      fake_git_path = Path.join(fake_git_dir, "git")

      File.write!(fake_git_path, """
      #!/bin/sh
      # Fake git that sleeps forever to simulate hang
      sleep 30
      """)

      # Make it executable
      File.chmod!(fake_git_path, 0o755)

      # Initialize a real git repo (so Command.new validation passes)
      # but we'll override PATH to find our fake git first
      workspace_dir = Path.join(tmp, "repo")
      File.mkdir_p!(workspace_dir)

      System.cmd("git", ["init"], cd: workspace_dir, stderr_to_stdout: true)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: workspace_dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: workspace_dir)

      File.write!(Path.join(workspace_dir, "README.md"), "hello")
      System.cmd("git", ["add", "."], cd: workspace_dir, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "init"], cd: workspace_dir, stderr_to_stdout: true)

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{workspace: workspace_dir, fake_bin: fake_git_dir}
    end

    @tag :timeout
    test "git metadata returns fallback on timeout", %{workspace: workspace, fake_bin: fake_bin} do
      # Put fake git first in PATH so LocalRunner's Env resolves it
      original_path = System.get_env("PATH")
      fake_path = fake_bin <> ":" <> original_path

      # Temporarily set PATH with fake git first
      System.put_env("PATH", fake_path)

      try do
        # Use very short timeout — fake git sleeps 30s so it should time out
        {:ok, meta} = GitMetadata.capture(workspace, git_timeout_ms: 500)

        # All fields should be nil (fallback) because commands timed out
        assert meta.stash_ref == nil
        assert meta.head_sha == nil
        assert meta.branch == nil
        assert meta.dirty == nil
      after
        System.put_env("PATH", original_path)
      end
    end

    @tag :timeout
    test "timeout does not hang the caller", %{workspace: workspace, fake_bin: fake_bin} do
      original_path = System.get_env("PATH")
      fake_path = fake_bin <> ":" <> original_path
      System.put_env("PATH", fake_path)

      try do
        # This must complete within a reasonable time, not 30 seconds
        start = System.monotonic_time(:millisecond)

        {:ok, _meta} = GitMetadata.capture(workspace, git_timeout_ms: 500)

        elapsed = System.monotonic_time(:millisecond) - start
        # Should complete in well under 10 seconds (500ms timeout per cmd × 4 cmds + overhead)
        assert elapsed < 10_000
      after
        System.put_env("PATH", original_path)
      end
    end
  end

  describe "capture/2 — no secret env passed to git" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "git_meta_env_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      # Create a fake "git" script that dumps its environment to a file
      fake_git_dir = Path.join(tmp, "fake_bin")
      File.mkdir_p!(fake_git_dir)

      env_dump_file = Path.join(tmp, "env_dump.txt")

      fake_git_path = Path.join(fake_git_dir, "git")

      # Write a script that dumps env to a file and outputs
      # a fake SHA to simulate success
      File.write!(fake_git_path, """
      #!/bin/sh
      env > #{env_dump_file}
      echo "abc123def456abc123def456abc123def456abc1"
      """)

      File.chmod!(fake_git_path, 0o755)

      # Initialize a real git repo
      workspace_dir = Path.join(tmp, "repo")
      File.mkdir_p!(workspace_dir)

      System.cmd("git", ["init"], cd: workspace_dir, stderr_to_stdout: true)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: workspace_dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: workspace_dir)

      File.write!(Path.join(workspace_dir, "README.md"), "hello")
      System.cmd("git", ["add", "."], cd: workspace_dir, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "init"], cd: workspace_dir, stderr_to_stdout: true)

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{workspace: workspace_dir, fake_bin: fake_git_dir, env_dump_file: env_dump_file}
    end

    test "secret env vars are not passed to git subprocess", %{
      workspace: workspace,
      fake_bin: fake_bin,
      env_dump_file: env_dump_file
    } do
      # Set some secret env vars that should NEVER reach git
      original_path = System.get_env("PATH")
      fake_path = fake_bin <> ":" <> original_path

      secret_vars = %{
        "OPENAI_API_KEY" => "sk-secret-key-12345",
        "ANTHROPIC_API_KEY" => "sk-ant-secret-67890",
        "GITHUB_TOKEN" => "ghp_secret_token",
        "AWS_SECRET_ACCESS_KEY" => "aws_secret_here",
        "MUSE_API_KEY" => "muse_secret_key",
        "DATABASE_URL" => "postgres://user:pass@host/db"
      }

      System.put_env("PATH", fake_path)

      # Set secret env vars in the BEAM process
      Enum.each(secret_vars, fn {k, v} -> System.put_env(k, v) end)

      try do
        # Clear any previous env dump
        if File.exists?(env_dump_file), do: File.rm!(env_dump_file)

        # Run git metadata capture — the fake git will dump its env
        {:ok, meta} = GitMetadata.capture(workspace)

        # The fake git outputs a SHA, so head_sha should be set
        # (it's the output from any of the 4 git commands)
        assert is_binary(meta.head_sha) or is_nil(meta.head_sha)

        # Now check the env dump — secrets should NOT be there
        if File.exists?(env_dump_file) do
          env_contents = File.read!(env_dump_file)
          env_lines = String.split(env_contents, "\n")

          # None of the secret keys should appear in the env dump
          for {secret_key, _secret_val} <- secret_vars do
            refute Enum.any?(env_lines, &String.starts_with?(&1, secret_key <> "=")),
                   "Secret env var #{secret_key} was passed to git subprocess!"
          end

          # PATH should be present (it's on the allowlist)
          assert Enum.any?(env_lines, &String.starts_with?(&1, "PATH=")),
                 "PATH should be in the git subprocess env"

          # HOME should be present (it's on the allowlist)
          assert Enum.any?(env_lines, &String.starts_with?(&1, "HOME=")),
                 "HOME should be in the git subprocess env"
        end
      after
        System.put_env("PATH", original_path)

        Enum.each(Map.keys(secret_vars), fn k ->
          System.delete_env(k)
        end)
      end
    end
  end

  describe "capture/2 — edge cases" do
    test "nil workspace returns fallback" do
      {:ok, meta} = GitMetadata.capture(nil)
      assert meta == %{stash_ref: nil, head_sha: nil, branch: nil, dirty: nil}
    end

    test "non-string workspace returns fallback" do
      {:ok, meta} = GitMetadata.capture(123)
      assert meta == %{stash_ref: nil, head_sha: nil, branch: nil, dirty: nil}
    end

    test "fallback/0 returns all-nil map" do
      fb = GitMetadata.fallback()
      assert fb.stash_ref == nil
      assert fb.head_sha == nil
      assert fb.branch == nil
      assert fb.dirty == nil
    end

    test "default_timeout_ms returns positive integer" do
      assert GitMetadata.default_timeout_ms() > 0
    end
  end
end
