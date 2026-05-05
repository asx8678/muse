defmodule Muse.PatchTest do
  use ExUnit.Case, async: true

  alias Muse.Patch

  # -- Helpers ------------------------------------------------------------------

  defp sample_diff do
    """
    diff --git a/lib/muse/commands.ex b/lib/muse/commands.ex
    --- a/lib/muse/commands.ex
    +++ b/lib/muse/commands.ex
    @@ -10,3 +10,4 @@
       existing_line
    -old_command
    +new_command
    +extra_command
    """
  end

  defp sample_patch(overrides \\ []) do
    defaults = [
      id: "patch_001",
      session_id: "sess_abc",
      plan_id: "plan_001",
      plan_version: 3,
      plan_hash: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
      diff: sample_diff(),
      created_at: ~U[2025-01-01 00:00:00Z]
    ]

    {:ok, patch} = Patch.new(Keyword.merge(defaults, overrides))
    patch
  end

  # -- new/1 --------------------------------------------------------------------

  describe "new/1" do
    test "creates a patch with required fields" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff()
        )

      assert %Patch{} = patch
      assert patch.status == :proposed
      assert patch.session_id == "s1"
      assert patch.plan_id == "p1"
      assert patch.plan_version == 1
      assert patch.plan_hash == "abc"
      assert patch.diff == sample_diff()
      assert is_binary(patch.hash)
      assert patch.affected_files == ["lib/muse/commands.ex"]
      assert patch.metadata == %{}
    end

    test "accepts deterministic id and timestamps for testing" do
      ts = ~U[2025-01-01 00:00:00Z]

      {:ok, patch} =
        Patch.new(
          id: "patch_1",
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff(),
          created_at: ts
        )

      assert patch.id == "patch_1"
      assert patch.created_at == ts
    end

    test "accepts custom initial status" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff(),
          status: :approved
        )

      assert patch.status == :approved
    end

    test "falls back to :proposed for invalid status" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff(),
          status: :unknown
        )

      assert patch.status == :proposed
    end

    test "accepts string status values, normalizing to atoms" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff(),
          status: "approved"
        )

      assert patch.status == :approved
    end

    test "falls back to :proposed for unknown string status" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff(),
          status: "nonexistent_status_value"
        )

      assert patch.status == :proposed
    end

    test "accepts map with string keys" do
      {:ok, patch} =
        Patch.new(%{
          "session_id" => "s1",
          "plan_id" => "p1",
          "plan_version" => 1,
          "plan_hash" => "abc",
          "diff" => sample_diff()
        })

      assert %Patch{} = patch
      assert patch.session_id == "s1"
    end

    test "unknown string keys from JSON are ignored without creating atoms" do
      before_atoms = :erlang.system_info(:atom_count)

      {:ok, patch} =
        Patch.new(%{
          "session_id" => "s1",
          "plan_id" => "p1",
          "plan_version" => 1,
          "plan_hash" => "abc",
          "diff" => sample_diff(),
          "unknown_patch_key_99999" => "should be ignored",
          "another_bogus_key" => "also ignored"
        })

      after_atoms = :erlang.system_info(:atom_count)

      assert %Patch{} = patch

      assert after_atoms - before_atoms < 3,
             "Unknown JSON keys should not create atoms: #{after_atoms - before_atoms} new atoms"
    end

    test "extracts affected files from diff" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff()
        )

      assert "lib/muse/commands.ex" in patch.affected_files
    end

    test "allows overriding affected files" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff(),
          affected_files: ["custom/path.ex"]
        )

      assert patch.affected_files == ["custom/path.ex"]
    end

    test "computes content hash automatically" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff()
        )

      assert is_binary(patch.hash)
      assert byte_size(patch.hash) == 64
      assert patch.hash == String.downcase(patch.hash)
    end

    test "rejects binary patch" do
      assert {:error, :binary_patch} =
               Patch.new(
                 session_id: "s1",
                 plan_id: "p1",
                 plan_version: 1,
                 plan_hash: "abc",
                 diff: "GIT binary patch\nliteral 0\nHcmV?d00001\n"
               )
    end

    test "handles empty diff" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: ""
        )

      assert %Patch{} = patch
      assert patch.affected_files == []
    end

    test "defaults metadata to empty map" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: ""
        )

      assert patch.metadata == %{}
    end
  end

  # -- statuses/0 ---------------------------------------------------------------

  describe "statuses/0" do
    test "returns the canonical list of patch statuses" do
      statuses = Patch.statuses()

      assert :proposed in statuses
      assert :approved in statuses
      assert :rejected in statuses
      assert :applied in statuses
      assert :verified in statuses
      assert :cancelled in statuses
    end

    test "all statuses are atoms" do
      for status <- Patch.statuses() do
        assert is_atom(status)
      end
    end

    test "has exactly 6 statuses" do
      assert length(Patch.statuses()) == 6
    end
  end

  # -- valid_status?/1 ----------------------------------------------------------

  describe "valid_status?/1" do
    test "returns true for canonical statuses" do
      for status <- Patch.statuses() do
        assert Patch.valid_status?(status)
      end
    end

    test "returns false for non-canonical values" do
      refute Patch.valid_status?(:unknown)
      refute Patch.valid_status?(nil)
      refute Patch.valid_status?("proposed")
    end
  end

  # -- transition/3 --------------------------------------------------------------

  describe "transition/3" do
    test "transitions to a valid status" do
      patch = sample_patch()

      assert {:ok, updated} = Patch.transition(patch, :approved)
      assert updated.status == :approved
    end

    test "sets approved_at when transitioning to :approved" do
      ts = ~U[2025-06-01 12:00:00Z]
      patch = sample_patch()

      {:ok, updated} = Patch.transition(patch, :approved, approved_at: ts)
      assert updated.approved_at == ts
    end

    test "sets rejected_at when transitioning to :rejected" do
      ts = ~U[2025-06-01 12:00:00Z]
      patch = sample_patch()

      {:ok, updated} = Patch.transition(patch, :rejected, rejected_at: ts)
      assert updated.rejected_at == ts
    end

    test "sets applied_at when transitioning to :applied" do
      ts = ~U[2025-06-01 12:00:00Z]
      patch = sample_patch()

      {:ok, updated} = Patch.transition(patch, :applied, applied_at: ts)
      assert updated.applied_at == ts
    end

    test "sets verified_at when transitioning to :verified" do
      ts = ~U[2025-06-01 12:00:00Z]
      patch = sample_patch()

      {:ok, updated} = Patch.transition(patch, :verified, verified_at: ts)
      assert updated.verified_at == ts
    end

    test "rejects invalid status" do
      patch = sample_patch()

      assert {:error, {:invalid_status, :unknown}} = Patch.transition(patch, :unknown)
    end

    test "preserves other fields through transition" do
      patch = sample_patch()

      {:ok, updated} = Patch.transition(patch, :approved)

      assert updated.id == patch.id
      assert updated.session_id == patch.session_id
      assert updated.plan_id == patch.plan_id
      assert updated.diff == patch.diff
      assert updated.hash == patch.hash
    end
  end

  # -- content_hash/1 ------------------------------------------------------------

  describe "content_hash/1" do
    test "returns a 64-character lowercase hex string" do
      patch = sample_patch()
      hash = Patch.content_hash(patch)

      assert is_binary(hash)
      assert byte_size(hash) == 64
      assert hash == String.downcase(hash)
    end

    test "is deterministic: same patch content produces same hash" do
      patch1 = sample_patch()
      patch2 = sample_patch()

      assert Patch.content_hash(patch1) == Patch.content_hash(patch2)
    end

    test "hash changes when diff changes" do
      patch_a = sample_patch()

      patch_b =
        sample_patch(
          diff: """
          diff --git a/other.ex b/other.ex
          --- a/other.ex
          +++ b/other.ex
          @@ -1 +1 @@
          -different
          +content
          """
        )

      refute Patch.content_hash(patch_a) == Patch.content_hash(patch_b)
    end

    test "hash changes when plan_id changes" do
      patch_a = sample_patch(plan_id: "plan_A")
      patch_b = sample_patch(plan_id: "plan_B")

      refute Patch.content_hash(patch_a) == Patch.content_hash(patch_b)
    end

    test "hash changes when plan_version changes" do
      patch_v1 = sample_patch(plan_version: 1)
      patch_v2 = sample_patch(plan_version: 2)

      refute Patch.content_hash(patch_v1) == Patch.content_hash(patch_v2)
    end

    test "hash changes when plan_hash changes" do
      patch_a = sample_patch(plan_hash: "hash_A")
      patch_b = sample_patch(plan_hash: "hash_B")

      refute Patch.content_hash(patch_a) == Patch.content_hash(patch_b)
    end

    test "hash changes when session_id changes" do
      patch_a = sample_patch(session_id: "sess_A")
      patch_b = sample_patch(session_id: "sess_B")

      refute Patch.content_hash(patch_a) == Patch.content_hash(patch_b)
    end
  end

  # -- content_hash/1 — volatile fields excluded --------------------------------

  describe "content_hash/1 — volatile fields excluded" do
    test "timestamps do not change the hash" do
      ts_early = ~U[2025-01-01 00:00:00Z]
      ts_late = ~U[2099-12-31 23:59:59Z]

      patch_early = sample_patch(created_at: ts_early)
      patch_late = sample_patch(created_at: ts_late)

      assert Patch.content_hash(patch_early) == Patch.content_hash(patch_late),
             "created_at must not affect hash"
    end

    test "approved_at does not change the hash" do
      patch_no_approval = sample_patch()

      {:ok, patch_approved} =
        Patch.transition(sample_patch(), :approved, approved_at: ~U[2025-06-01 12:00:00Z])

      assert Patch.content_hash(patch_no_approval) ==
               Patch.content_hash(patch_approved),
             "approved_at must not affect hash"
    end

    test "status does not change the hash" do
      patch_proposed = sample_patch(status: :proposed)
      patch_approved = sample_patch(status: :approved)
      patch_rejected = sample_patch(status: :rejected)

      hash = Patch.content_hash(patch_proposed)

      assert Patch.content_hash(patch_approved) == hash
      assert Patch.content_hash(patch_rejected) == hash
    end

    test "metadata does not change the hash" do
      patch_no_meta = sample_patch()
      patch_with_meta = sample_patch(metadata: %{"extra" => "info", "count" => 42})

      assert Patch.content_hash(patch_no_meta) == Patch.content_hash(patch_with_meta),
             "metadata must not affect hash"
    end

    test "id does not change the hash" do
      patch_a = sample_patch(id: "patch_A")
      patch_b = sample_patch(id: "patch_B")

      assert Patch.content_hash(patch_a) == Patch.content_hash(patch_b),
             "id must not affect hash"
    end
  end

  # -- content_hash/1 — determinism stress ---------------------------------------

  describe "content_hash/1 — determinism stress" do
    test "hash is stable over 100 calls on the same patch" do
      patch = sample_patch()
      hash = Patch.content_hash(patch)

      for _ <- 1..100 do
        assert Patch.content_hash(patch) == hash
      end
    end

    test "hash is identical for patches constructed with identical content" do
      patches =
        for _ <- 1..10 do
          sample_patch()
        end

      hashes = Enum.map(patches, &Patch.content_hash/1)

      assert Enum.uniq(hashes) |> length() == 1,
             "All identical patches must produce the same hash"
    end
  end

  # -- canonical_diff/1 ----------------------------------------------------------

  describe "canonical_diff/1" do
    test "normalizes the diff for stable display" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: "--- a/f.ex\r\n+++ b/f.ex\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n"
        )

      canonical = Patch.canonical_diff(patch)
      refute String.contains?(canonical, "\r")
      assert String.ends_with?(canonical, "\n")
    end

    test "is idempotent" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff()
        )

      once = Patch.canonical_diff(patch)
      twice = Patch.canonical_diff(%{patch | diff: once})
      assert once == twice
    end
  end

  # -- affected_files/1 ----------------------------------------------------------

  describe "affected_files/1" do
    test "returns file paths extracted from diff" do
      patch = sample_patch()
      assert "lib/muse/commands.ex" in Patch.affected_files(patch)
    end

    test "returns override paths when provided" do
      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: sample_diff(),
          affected_files: ["custom.ex"]
        )

      assert Patch.affected_files(patch) == ["custom.ex"]
    end
  end

  # -- to_map/1 ------------------------------------------------------------------

  describe "to_map/1" do
    test "converts struct to plain map" do
      patch = sample_patch()
      map = Patch.to_map(patch)

      assert is_map(map)
      assert map[:session_id] == "sess_abc"
      assert map[:plan_id] == "plan_001"
      assert map[:status] == :proposed
    end

    test "drops nil values" do
      patch = sample_patch()
      map = Patch.to_map(patch)

      refute Map.has_key?(map, :approved_at)
      refute Map.has_key?(map, :rejected_at)
      refute Map.has_key?(map, :applied_at)
      refute Map.has_key?(map, :verified_at)
    end
  end

  # -- from_map/1 ----------------------------------------------------------------

  describe "from_map/1" do
    test "creates patch from plain map" do
      {:ok, patch} =
        Patch.from_map(%{
          "session_id" => "s1",
          "plan_id" => "p1",
          "plan_version" => 1,
          "plan_hash" => "abc",
          "diff" => sample_diff()
        })

      assert %Patch{} = patch
      assert patch.session_id == "s1"
      assert patch.plan_id == "p1"
    end

    test "round-trips through to_map and from_map" do
      original = sample_patch()
      map = Patch.to_map(original)
      {:ok, restored} = Patch.from_map(map)

      assert restored.session_id == original.session_id
      assert restored.plan_id == original.plan_id
      assert restored.plan_version == original.plan_version
      assert restored.plan_hash == original.plan_hash
      assert restored.diff == original.diff
      assert restored.status == original.status
      assert restored.affected_files == original.affected_files
    end

    test "round-trips through JSON" do
      original = sample_patch()

      decoded =
        original
        |> Patch.to_map()
        |> Jason.encode!()
        |> Jason.decode!()

      {:ok, restored} = Patch.from_map(decoded)

      assert restored.session_id == original.session_id
      assert restored.plan_id == original.plan_id
      assert restored.plan_version == original.plan_version
      assert restored.plan_hash == original.plan_hash
      assert restored.diff == original.diff
      assert restored.status == original.status
      assert restored.affected_files == original.affected_files
    end

    test "hash survives JSON round-trip" do
      original = sample_patch()

      {:ok, restored} =
        original
        |> Patch.to_map()
        |> Jason.encode!()
        |> Jason.decode!()
        |> Patch.from_map()

      # The hash must be identical since content hasn't changed
      assert Patch.content_hash(restored) == Patch.content_hash(original)
      # And the stored hash should also match
      assert restored.hash == original.hash
    end

    test "does not create atoms from unknown JSON keys" do
      before_atoms = :erlang.system_info(:atom_count)

      {:ok, patch} =
        Patch.from_map(%{
          "session_id" => "s1",
          "plan_id" => "p1",
          "plan_version" => 1,
          "plan_hash" => "abc",
          "diff" => "",
          "unknown_patch_key_xyzzy" => "ignored"
        })

      after_atoms = :erlang.system_info(:atom_count)

      assert %Patch{} = patch
      assert after_atoms - before_atoms < 3
    end

    test "rejects binary patch in from_map" do
      assert {:error, :binary_patch} =
               Patch.from_map(%{
                 "session_id" => "s1",
                 "plan_id" => "p1",
                 "plan_version" => 1,
                 "plan_hash" => "abc",
                 "diff" => "GIT binary patch\n"
               })
    end
  end

  # -- approval_binding/2 --------------------------------------------------------

  describe "approval_binding/2" do
    test "returns all required binding fields" do
      patch = sample_patch()
      binding = Patch.approval_binding(patch, workspace: "/tmp/project")

      assert binding.kind == "patch_approval"
      assert binding.session_id == "sess_abc"
      assert binding.patch_id == "patch_001"
      assert binding.plan_id == "plan_001"
      assert binding.plan_version == 3

      assert binding.plan_hash ==
               "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

      assert binding.patch_hash == patch.hash
      assert binding.workspace == "/tmp/project"
    end

    test "workspace defaults to nil" do
      patch = sample_patch()
      binding = Patch.approval_binding(patch)

      assert binding.workspace == nil
    end

    test "binding contains no raw diff content" do
      patch = sample_patch()
      binding = Patch.approval_binding(patch)
      inspected = inspect(binding)

      refute Map.has_key?(binding, :diff)
      # The diff content should not appear in the binding
      refute String.contains?(inspected, "old_command")
      refute String.contains?(inspected, "new_command")
    end

    test "includes affected_files" do
      patch = sample_patch()
      binding = Patch.approval_binding(patch)

      assert "lib/muse/commands.ex" in binding.affected_files
    end

    test "binding fields are all atom-keyed" do
      patch = sample_patch()
      binding = Patch.approval_binding(patch)

      for key <- Map.keys(binding) do
        assert is_atom(key), "Binding key #{inspect(key)} should be an atom"
      end
    end
  end

  # -- Multi-file diff -----------------------------------------------------------

  describe "multi-file diff" do
    test "extracts affected files from multi-file diff" do
      diff = """
      diff --git a/lib/first.ex b/lib/first.ex
      --- a/lib/first.ex
      +++ b/lib/first.ex
      @@ -1 +1 @@
      -old1
      +new1
      diff --git a/lib/second.ex b/lib/second.ex
      --- a/lib/second.ex
      +++ b/lib/second.ex
      @@ -1 +1 @@
      -old2
      +new2
      """

      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: diff
        )

      assert "lib/first.ex" in patch.affected_files
      assert "lib/second.ex" in patch.affected_files
      assert length(patch.affected_files) == 2
    end

    test "hash is different for single-file vs multi-file diff" do
      single_diff = """
      --- a/one.ex
      +++ b/one.ex
      @@ -1 +1 @@
      -old
      +new
      """

      multi_diff = """
      diff --git a/one.ex b/one.ex
      --- a/one.ex
      +++ b/one.ex
      @@ -1 +1 @@
      -old
      +new
      diff --git a/two.ex b/two.ex
      --- a/two.ex
      +++ b/two.ex
      @@ -1 +1 @@
      -old2
      +new2
      """

      {:ok, patch_single} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: single_diff
        )

      {:ok, patch_multi} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: multi_diff
        )

      refute Patch.content_hash(patch_single) == Patch.content_hash(patch_multi)
    end
  end

  # -- Path security (model layer) -----------------------------------------------

  describe "path security (model layer)" do
    test "affected files with directory traversal are still extracted as paths" do
      # The model layer does not enforce workspace security — that is
      # lane09's responsibility. We verify that paths are faithfully extracted.
      diff = """
      --- a/../../../etc/passwd
      +++ b/../../../etc/passwd
      @@ -1 +1 @@
      -root:x:0:0
      +hacked:x:0:0
      """

      {:ok, patch} =
        Patch.new(
          session_id: "s1",
          plan_id: "p1",
          plan_version: 1,
          plan_hash: "abc",
          diff: diff
        )

      # The model layer faithfully records the path; security enforcement
      # is the responsibility of the workspace layer (lane09).
      assert "../../../etc/passwd" in patch.affected_files
    end
  end
end
