defmodule Muse.WorkspaceProfileTest do
  use ExUnit.Case, async: false

  alias Muse.WorkspaceProfile

  setup do
    muse_dir = tmp_dir!()

    on_exit(fn ->
      File.rm_rf!(muse_dir)
    end)

    %{muse_dir: muse_dir}
  end

  defp tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "muse-workspace-profile-test-#{suffix}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  # ── create/1 ──────────────────────────────────────────────────────────

  describe "create/1" do
    test "creates a workspace profile", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "myproject")
      File.mkdir_p!(root)

      assert {:ok, profile} =
               WorkspaceProfile.create(
                 name: "myproject",
                 root_path: root,
                 muse_dir: muse_dir
               )

      assert profile.name == "myproject"
      assert profile.root_path == Path.expand(root)
      assert profile.sessions_dir == Path.join(Path.expand(root), ".muse/sessions")
      assert is_binary(profile.created_at)
      assert is_binary(profile.updated_at)
    end

    test "rejects nil name" do
      assert {:error, :name_required} = WorkspaceProfile.create(name: nil, root_path: "/tmp")
    end

    test "rejects empty name" do
      assert {:error, :name_required} = WorkspaceProfile.create(name: "", root_path: "/tmp")
    end

    test "rejects path-traversal names" do
      assert {:error, {:invalid_profile_name, "../escape"}} =
               WorkspaceProfile.create(name: "../escape", root_path: "/tmp")
    end

    test "rejects dot-only names" do
      assert {:error, {:invalid_profile_name, "."}} =
               WorkspaceProfile.create(name: ".", root_path: "/tmp")

      assert {:error, {:invalid_profile_name, ".."}} =
               WorkspaceProfile.create(name: "..", root_path: "/tmp")
    end

    test "rejects names with slashes" do
      assert {:error, {:invalid_profile_name, "foo/bar"}} =
               WorkspaceProfile.create(name: "foo/bar", root_path: "/tmp")
    end

    test "rejects nil root_path" do
      assert {:error, :root_path_required} = WorkspaceProfile.create(name: "test", root_path: nil)
    end

    test "rejects empty root_path" do
      assert {:error, :root_path_required} = WorkspaceProfile.create(name: "test", root_path: "")
    end

    test "creates muse_dir if it doesn't exist", %{muse_dir: muse_dir} do
      new_muse_dir = Path.join(muse_dir, "new-muse-dir")
      root = Path.join(new_muse_dir, "project")

      File.mkdir_p!(root)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "test",
                 root_path: root,
                 muse_dir: new_muse_dir
               )

      assert File.dir?(new_muse_dir)
    end

    test "updates existing profile with same name", %{muse_dir: muse_dir} do
      root1 = Path.join(muse_dir, "v1")
      root2 = Path.join(muse_dir, "v2")
      File.mkdir_p!(root1)
      File.mkdir_p!(root2)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "myproject",
                 root_path: root1,
                 muse_dir: muse_dir
               )

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "myproject",
                 root_path: root2,
                 muse_dir: muse_dir
               )

      assert {:ok, profiles} = WorkspaceProfile.list_profiles(muse_dir)
      # Only one profile with this name
      myproject_profiles =
        Enum.filter(profiles, fn p ->
          Map.get(p, "name") == "myproject" or Map.get(p, :name) == "myproject"
        end)

      assert length(myproject_profiles) == 1
    end
  end

  # ── list_profiles/1 ──────────────────────────────────────────────────

  describe "list_profiles/1" do
    test "returns empty list when no profiles exist", %{muse_dir: muse_dir} do
      assert {:ok, []} = WorkspaceProfile.list_profiles(muse_dir)
    end

    test "returns empty list when muse_dir doesn't exist" do
      assert {:ok, []} = WorkspaceProfile.list_profiles("/nonexistent/path")
    end

    test "lists created profiles", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "proj1")
      File.mkdir_p!(root)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "proj1",
                 root_path: root,
                 muse_dir: muse_dir
               )

      assert {:ok, profiles} = WorkspaceProfile.list_profiles(muse_dir)
      assert length(profiles) == 1
    end
  end

  # ── get_profile/2 ─────────────────────────────────────────────────────

  describe "get_profile/2" do
    test "returns existing profile", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "myproj")
      File.mkdir_p!(root)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "myproj",
                 root_path: root,
                 muse_dir: muse_dir
               )

      assert {:ok, profile} = WorkspaceProfile.get_profile("myproj", muse_dir)
      assert profile.name == "myproj"
    end

    test "returns not_found for non-existent profile", %{muse_dir: muse_dir} do
      assert {:error, :not_found} = WorkspaceProfile.get_profile("nonexistent", muse_dir)
    end
  end

  # ── delete_profile/2 ──────────────────────────────────────────────────

  describe "delete_profile/2" do
    test "deletes an existing profile", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "todelete")
      File.mkdir_p!(root)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "todelete",
                 root_path: root,
                 muse_dir: muse_dir
               )

      assert :ok = WorkspaceProfile.delete_profile("todelete", muse_dir)
      assert {:error, :not_found} = WorkspaceProfile.get_profile("todelete", muse_dir)
    end

    test "returns not_found for non-existent profile", %{muse_dir: muse_dir} do
      assert {:error, :not_found} = WorkspaceProfile.delete_profile("nonexistent", muse_dir)
    end
  end

  # ── sessions_dir_for/1 ────────────────────────────────────────────────

  describe "sessions_dir_for/1" do
    test "returns sessions dir for existing profile", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "proj")
      File.mkdir_p!(root)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "proj",
                 root_path: root,
                 muse_dir: muse_dir
               )

      assert {:ok, sessions_dir} = WorkspaceProfile.sessions_dir_for("proj", muse_dir: muse_dir)
      assert sessions_dir == Path.join(Path.expand(root), ".muse/sessions")
    end

    test "falls back to root-derived sessions dir for legacy profiles", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "legacy-proj")
      File.mkdir_p!(root)

      legacy_profile = [
        %{
          "name" => "legacy",
          "root_path" => Path.expand(root),
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-01T00:00:00Z"
        }
      ]

      File.write!(Path.join(muse_dir, "profiles.json"), Jason.encode!(legacy_profile))

      assert {:ok, sessions_dir} = WorkspaceProfile.sessions_dir_for("legacy", muse_dir: muse_dir)
      assert sessions_dir == Path.join(Path.expand(root), ".muse/sessions")
    end

    test "returns error for non-existent profile" do
      assert {:error, :not_found} = WorkspaceProfile.sessions_dir_for("nonexistent")
    end
  end

  # ── sessions_dir_from_root/1 ──────────────────────────────────────────

  describe "sessions_dir_from_root/1" do
    test "derives sessions dir from root path" do
      assert WorkspaceProfile.sessions_dir_from_root("/tmp/project") ==
               "/tmp/project/.muse/sessions"
    end

    test "works with relative paths" do
      assert WorkspaceProfile.sessions_dir_from_root("myproject") ==
               "myproject/.muse/sessions"
    end
  end

  # ── Profile isolation ─────────────────────────────────────────────────

  describe "profile session isolation" do
    test "different profiles have different session directories", %{muse_dir: muse_dir} do
      root_a = Path.join(muse_dir, "proj-a")
      root_b = Path.join(muse_dir, "proj-b")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "proj-a",
                 root_path: root_a,
                 muse_dir: muse_dir
               )

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "proj-b",
                 root_path: root_b,
                 muse_dir: muse_dir
               )

      assert {:ok, dir_a} = WorkspaceProfile.sessions_dir_for("proj-a", muse_dir: muse_dir)
      assert {:ok, dir_b} = WorkspaceProfile.sessions_dir_for("proj-b", muse_dir: muse_dir)

      refute dir_a == dir_b
    end
  end

  # ── No secrets in profiles ────────────────────────────────────────────

  describe "secrets safety" do
    test "profiles.json does not contain sensitive keys", %{muse_dir: muse_dir} do
      root = Path.join(muse_dir, "safe-proj")
      File.mkdir_p!(root)

      assert {:ok, _} =
               WorkspaceProfile.create(
                 name: "safe-proj",
                 root_path: root,
                 muse_dir: muse_dir
               )

      {:ok, raw} = File.read(Path.join(muse_dir, "profiles.json"))

      # Profile data should not contain any secret patterns
      refute String.contains?(raw, "sk-")
      refute String.contains?(raw, "Bearer")
      refute String.contains?(raw, "password")
      refute String.contains?(raw, "api_key")
    end
  end
end
