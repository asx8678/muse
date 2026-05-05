defmodule Muse.Patch.ValidatorTest do
  use ExUnit.Case, async: true

  alias Muse.Patch.Validator

  setup do
    root =
      Path.join(System.tmp_dir!(), "muse_patch_validator_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/app.ex"), "defmodule App do\n  def version, do: 1\nend\n")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  describe "validate/3 accepts safe text patches" do
    test "returns safe metadata and does not write affected files", %{root: root} do
      before = File.read!(Path.join(root, "lib/app.ex"))

      assert {:ok, result} = Validator.validate(valid_diff(), root)

      assert result.affected_files == ["lib/app.ex"]
      assert result.file_count == 1
      assert result.diff_bytes == byte_size(valid_diff())
      assert result.diff_preview =~ "diff --git a/lib/app.ex b/lib/app.ex"
      refute result.preview_truncated
      refute Map.has_key?(result, :diff)
      refute Map.has_key?(result, "diff")
      assert File.read!(Path.join(root, "lib/app.ex")) == before
    end

    test "supports new-file /dev/null markers without treating them as target paths", %{
      root: root
    } do
      diff = """
      diff --git a/lib/new_file.ex b/lib/new_file.ex
      new file mode 100644
      index 0000000..1111111
      --- /dev/null
      +++ b/lib/new_file.ex
      @@ -0,0 +1 @@
      +defmodule NewFile, do: nil
      """

      assert {:ok, result} = Validator.validate(diff, root)
      assert result.affected_files == ["lib/new_file.ex"]
      refute File.exists?(Path.join(root, "lib/new_file.ex"))
    end

    test "validate_proposal/3 accepts future patch_propose style args", %{root: root} do
      assert {:ok, result} =
               Validator.validate_proposal(%{"patch" => valid_diff()}, %{workspace: root})

      assert result.affected_files == ["lib/app.ex"]
    end
  end

  describe "path boundary validation" do
    test "rejects absolute paths", %{root: root} do
      diff = diff_with_headers("/etc/passwd", "b/lib/app.ex")

      assert {:error, error} = Validator.validate(diff, root)
      assert error.reason == :unsafe_path
      assert error.message =~ "absolute paths are not allowed"
    end

    test "rejects Windows absolute paths and backslash traversal", %{root: root} do
      windows_abs = diff_with_headers("C:/Users/adam/.ssh/id_rsa", "b/lib/app.ex")
      backslash_traversal = diff_with_headers("a/lib/app.ex", "b/..\\outside.ex")

      assert {:error, error} = Validator.validate(windows_abs, root)
      assert error.reason == :unsafe_path
      assert error.message =~ "Windows absolute paths are not allowed"

      assert {:error, error} = Validator.validate(backslash_traversal, root)
      assert error.reason == :unsafe_path
      assert error.message =~ "backslash path separators are not allowed"
    end

    test "rejects .. traversal even when it would normalize inside", %{root: root} do
      diff = diff_with_headers("a/lib/../app.ex", "b/lib/app.ex")

      assert {:error, error} = Validator.validate(diff, root)
      assert error.reason == :unsafe_path
      assert error.message =~ ".. traversal is not allowed"
    end

    test "rejects .git internals", %{root: root} do
      diff = diff_with_headers("a/.git/config", "b/.git/config")

      assert {:error, error} = Validator.validate(diff, root)
      assert error.reason == :unsafe_path
      assert error.message =~ "workspace safety rules"
    end

    test "rejects existing symlink escapes outside the workspace", %{root: root} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "muse_patch_validator_outside_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.ex"), "secret")
      on_exit(fn -> File.rm_rf(outside) end)

      link = Path.join(root, "external")

      case File.ln_s(outside, link) do
        :ok ->
          diff = diff_with_headers("a/external/secret.ex", "b/external/secret.ex")

          assert {:error, error} = Validator.validate(diff, root)
          assert error.reason == :unsafe_path
          assert error.message =~ "workspace safety rules"

        {:error, _reason} ->
          :ok
      end
    end
  end

  describe "secret path denylist" do
    test "rejects common secret and credential paths", %{root: root} do
      secret_paths = [
        ".env",
        ".env.local",
        "server.pem",
        "private.key",
        "auth.json",
        "auth.yml",
        "credentials.json",
        "credentials.yml",
        "application_default_credentials.json",
        ".aws/credentials",
        ".docker/config.json",
        ".kube/config"
      ]

      for path <- secret_paths do
        diff = diff_with_headers("a/#{path}", "b/#{path}")

        assert {:error, error} = Validator.validate(diff, root), "expected #{path} to be rejected"
        assert error.reason == :unsafe_path
      end
    end

    test "allows non-secret hidden project files while still using workspace safety", %{
      root: root
    } do
      diff = diff_with_headers("a/.formatter.exs", "b/.formatter.exs")

      assert {:ok, result} = Validator.validate(diff, root)
      assert result.affected_files == [".formatter.exs"]
    end
  end

  describe "binary and size limits" do
    test "rejects Git binary patch markers", %{root: root} do
      diff = """
      diff --git a/priv/blob.png b/priv/blob.png
      index 1111111..2222222 100644
      GIT binary patch
      literal 4
      abcd
      """

      assert {:error, error} = Validator.validate(diff, root)
      assert error.reason == :binary_patch
    end

    test "rejects Binary files markers", %{root: root} do
      diff = "Binary files a/priv/blob.png and b/priv/blob.png differ\n"

      assert {:error, error} = Validator.validate(diff, root)
      assert error.reason == :binary_patch
    end

    test "rejects NUL bytes and invalid UTF-8", %{root: root} do
      assert {:error, nul_error} = Validator.validate(valid_diff() <> <<0>>, root)
      assert nul_error.reason == :binary_patch

      assert {:error, utf8_error} = Validator.validate("diff --git a/a b/a\n" <> <<255>>, root)
      assert utf8_error.reason == :binary_patch
    end

    test "enforces maximum diff bytes", %{root: root} do
      assert {:error, error} = Validator.validate(valid_diff(), root, max_diff_bytes: 20)
      assert error.reason == :diff_too_large
      assert error.limit == 20
    end

    test "enforces maximum affected files", %{root: root} do
      diff =
        1..3
        |> Enum.map(fn i -> valid_diff("lib/file_#{i}.ex") end)
        |> Enum.join("\n")

      assert {:error, error} = Validator.validate(diff, root, max_files: 2)
      assert error.reason == :too_many_files
      assert error.limit == 2
    end

    test "enforces maximum line length without echoing the line", %{root: root} do
      secret = "API_KEY=sk-test-line-secret-123456"
      long_line = "+" <> String.duplicate("a", 80) <> secret
      diff = valid_diff("lib/app.ex", long_line)

      assert {:error, error} = Validator.validate(diff, root, max_line_bytes: 40)
      assert error.reason == :line_too_long
      assert error.line > 0
      refute error.message =~ secret
    end
  end

  describe "safe previews for events and external envelopes" do
    test "redacts secret-like strings and does not return raw diff", %{root: root} do
      secret = "sk-test-preview-secret-123456"

      diff =
        valid_diff(
          "lib/app.ex",
          "+API_KEY=#{secret}\n+DATABASE_URL=postgres://user:pass@example/db"
        )

      assert {:ok, result} = Validator.validate(diff, root)
      refute result.diff_preview =~ secret
      refute result.diff_preview =~ "postgres://user:pass@example"
      assert result.diff_preview =~ "[REDACTED]"
      refute Map.has_key?(result, :raw_diff)
      refute Map.has_key?(result, :patch)
    end

    test "caps redacted diff previews", %{root: root} do
      diff = valid_diff("lib/app.ex", "+" <> String.duplicate("x", 2_000))

      assert {:ok, result} = Validator.validate(diff, root, max_preview_bytes: 200)
      assert result.preview_truncated
      assert byte_size(result.diff_preview) <= 200
      assert result.diff_preview =~ "diff preview truncated"
    end

    test "redacts unsafe path messages before they can be logged", %{root: root} do
      secret_path = "a/lib/API_KEY=sk-test-path-secret-123456/../../outside.ex"
      diff = diff_with_headers(secret_path, "b/lib/app.ex")

      assert {:error, error} = Validator.validate(diff, root)
      refute error.message =~ "sk-test-path-secret-123456"
      refute error.path =~ "sk-test-path-secret-123456"
      assert error.message =~ "[REDACTED]"
    end
  end

  defp valid_diff(path \\ "lib/app.ex", added_line \\ "+  def version, do: 2") do
    """
    diff --git a/#{path} b/#{path}
    index 1111111..2222222 100644
    --- a/#{path}
    +++ b/#{path}
    @@ -1,3 +1,3 @@
     defmodule App do
    -  def version, do: 1
    #{added_line}
     end
    """
  end

  defp diff_with_headers(old_path, new_path) do
    """
    diff --git #{old_path} #{new_path}
    index 1111111..2222222 100644
    --- #{old_path}
    +++ #{new_path}
    @@ -1 +1 @@
    -old
    +new
    """
  end
end
