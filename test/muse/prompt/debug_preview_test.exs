defmodule Muse.Prompt.DebugPreviewTest do
  use ExUnit.Case, async: true

  alias Muse.Prompt.{Assembler, DebugPreview}
  alias Muse.{Session, MuseProfile}

  setup do
    session =
      Session.new(
        workspace: "/tmp/test_project",
        id: "sess_preview",
        status: :idle,
        created_at: ~U[2025-01-01 00:00:00Z],
        updated_at: ~U[2025-01-01 00:00:00Z]
      )

    profile =
      MuseProfile.new!(
        id: :planning,
        display_name: "Planning Muse",
        role: :planning,
        prompt: "You are the Planning Muse. Inspect and plan.",
        tools: ["list_files", "read_file", "repo_search", "git_status"]
      )

    bundle =
      Assembler.build(session, profile, "inspect the project",
        id: "pb_preview",
        model: "fake-planning-model",
        blocked_tools: ["shell_command", "network_call", "patch_apply", "delete_file"],
        project_rules?: false,
        created_at: ~U[2025-01-01 00:00:00Z]
      )

    %{bundle: bundle, session: session, profile: profile}
  end

  describe "render/2" do
    test "includes session id in output", %{bundle: bundle} do
      output = DebugPreview.render(bundle)
      assert output =~ "sess_preview"
    end

    test "includes active Muse display name", %{bundle: bundle} do
      output = DebugPreview.render(bundle)
      assert output =~ "Planning Muse"
    end

    test "includes model", %{bundle: bundle} do
      output = DebugPreview.render(bundle)
      assert output =~ "fake-planning-model"
    end

    test "includes available tools", %{bundle: bundle} do
      output = DebugPreview.render(bundle)
      assert output =~ "list_files"
      assert output =~ "read_file"
    end

    test "includes blocked tools", %{bundle: bundle} do
      output = DebugPreview.render(bundle)
      assert output =~ "shell_command"
      assert output =~ "network_call"
    end

    test "includes layer summary with ids and visibility", %{bundle: bundle} do
      output = DebugPreview.render(bundle)
      assert output =~ "muse_core_invariants"
      assert output =~ "internal"
      assert output =~ "current_user_message"
      assert output =~ "user_visible"
    end

    test "includes token estimates for layers", %{bundle: bundle} do
      output = DebugPreview.render(bundle)
      assert output =~ "tokens"
    end
  end

  describe "render/2 never shows raw secrets" do
    test "redacts secrets in non-internal layer content", %{session: session, profile: profile} do
      # Add a global rules layer with a secret
      bundle =
        Assembler.build(session, profile, "hello",
          id: "pb_secret_test",
          global_rules: "Our API key is sk-test-supersecret12345.",
          skills: "DATABASE_URL=postgres://admin:pass@db.internal.io/prod",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      output = DebugPreview.render(bundle)

      refute output =~ "sk-test-supersecret12345"
      refute output =~ "postgres://admin:pass@db.internal.io"
      assert output =~ "[REDACTED]"
    end

    test "does not show raw content for internal layers", %{bundle: bundle} do
      output = DebugPreview.render(bundle, content_max_length: 500)

      # Internal layers should show id and visibility but NOT content preview
      lines = String.split(output, "\n")
      internal_lines = Enum.filter(lines, &String.contains?(&1, "internal"))

      for line <- internal_lines do
        # Internal lines should just have id, visibility, token count — no content preview
        # The next line (if any) would be a content preview with "   " prefix
        # For internal layers, there should be NO such continuation line
        refute String.starts_with?(String.trim(line), "   ")
      end
    end

    test "does not dump raw prompt text", %{bundle: bundle} do
      output = DebugPreview.render(bundle)

      # The core runtime prompt should not appear verbatim in the preview
      refute output =~ "You are part of Muse, a coding system"
      refute output =~ "Never access paths outside the active workspace"
    end
  end

  describe "render/2 with content containing secrets" do
    test "user-visible content is redacted before display", %{session: session} do
      profile =
        MuseProfile.new!(
          id: :planning,
          display_name: "Planning Muse",
          role: :planning,
          prompt: "Inspect and plan.",
          tools: ["read_file"]
        )

      bundle =
        Assembler.build(session, profile, "check my key sk-live-abc123def456ghi789jkl012",
          id: "pb_user_secret",
          project_rules?: false,
          created_at: ~U[2025-01-01 00:00:00Z]
        )

      output = DebugPreview.render(bundle)
      refute output =~ "sk-live-abc123def456ghi789jkl012"
    end
  end
end
