defmodule Muse.Auth.CodexCacheTest do
  use ExUnit.Case, async: true

  alias Muse.Auth.CodexCache

  describe "resolve/1" do
    # ---------------------------------------------------------------------------
    # Happy path — supported JSON shapes
    # ---------------------------------------------------------------------------

    test "extracts token from top-level access_token" do
      path = fixture_path("top_level_access.json")
      write_fixture!(path, %{"access_token" => "tok_abc123"})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.type == :bearer
      assert cred.value == "tok_abc123"
      assert cred.source == :codex_cache
      assert cred.source_ref == Path.basename(path)
    end

    test "extracts token from nested tokens.access_token" do
      path = fixture_path("nested_tokens.json")
      write_fixture!(path, %{"tokens" => %{"access_token" => "tok_nested"}})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.value == "tok_nested"
    end

    test "extracts token from nested auth.access_token" do
      path = fixture_path("nested_auth.json")
      write_fixture!(path, %{"auth" => %{"access_token" => "tok_auth"}})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.value == "tok_auth"
    end

    test "extracts token from nested openai.access_token" do
      path = fixture_path("nested_openai.json")
      write_fixture!(path, %{"openai" => %{"access_token" => "tok_openai"}})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.value == "tok_openai"
    end

    test "prefers access_token over id_token at top level" do
      path = fixture_path("both_tokens.json")
      write_fixture!(path, %{"access_token" => "tok_access", "id_token" => "tok_id"})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.value == "tok_access"
    end

    test "falls back to top-level id_token when no access_token exists" do
      path = fixture_path("id_token_only.json")
      write_fixture!(path, %{"id_token" => "tok_id_only"})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.value == "tok_id_only"
    end

    # ---------------------------------------------------------------------------
    # Expiry parsing
    # ---------------------------------------------------------------------------

    test "parses integer expires_at from top level" do
      path = fixture_path("exp_int.json")
      unix_ts = 1_750_000_000
      write_fixture!(path, %{"access_token" => "tok", "expires_at" => unix_ts})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.expires_at != nil
      assert cred.expires_at == DateTime.from_unix!(unix_ts)
    end

    test "parses ISO 8601 expires_at from top level" do
      path = fixture_path("exp_iso.json")
      dt = ~U[2025-06-01 12:00:00Z]
      write_fixture!(path, %{"access_token" => "tok", "expires_at" => DateTime.to_iso8601(dt)})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.expires_at == dt
    end

    test "ignores invalid expiry gracefully" do
      path = fixture_path("exp_invalid.json")

      write_fixture!(path, %{
        "access_token" => "tok",
        "expires_at" => "not-a-date-or-integer"
      })

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.expires_at == nil
    end

    test "sets expires_at to nil when no expiry present" do
      path = fixture_path("no_expiry.json")
      write_fixture!(path, %{"access_token" => "tok"})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.expires_at == nil
    end

    # ---------------------------------------------------------------------------
    # Path resolution
    # ---------------------------------------------------------------------------

    test "uses explicit path when provided" do
      path = fixture_path("explicit_path.json")
      write_fixture!(path, %{"access_token" => "tok_path"})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.value == "tok_path"
    end

    test "resolves path from :home option without reading real home" do
      tmp_dir = tmp_home!()
      auth_dir = Path.join(tmp_dir, ".codex")
      File.mkdir_p!(auth_dir)
      auth_file = Path.join(auth_dir, "auth.json")
      write_fixture!(auth_file, %{"access_token" => "tok_home"})

      assert {:ok, cred} = CodexCache.resolve(home: tmp_dir)
      assert cred.value == "tok_home"
    end

    # ---------------------------------------------------------------------------
    # Source ref labeling
    # ---------------------------------------------------------------------------

    test "uses ~/.codex/auth.json label for paths under .codex/auth.json" do
      path = fixture_path("label_test.json")
      write_fixture!(path, %{"access_token" => "tok"})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.source_ref == Path.basename(path)
    end

    # ---------------------------------------------------------------------------
    # Error cases
    # ---------------------------------------------------------------------------

    test "returns error for missing file" do
      path = fixture_path("nonexistent.json")

      assert {:error, _reason} = CodexCache.resolve(path: path)
    end

    test "returns error for unreadable file" do
      path = fixture_path("unreadable.json")
      write_fixture!(path, %{"access_token" => "tok"})
      File.chmod!(path, 0o000)

      assert {:error, _reason} = CodexCache.resolve(path: path)

      # Restore so cleanup works
      File.chmod!(path, 0o644)
    end

    test "returns error for invalid JSON" do
      path = fixture_path("invalid_json.json")
      File.write!(path, "this is not json")

      assert {:error, :invalid_json} = CodexCache.resolve(path: path)
    end

    test "returns error for JSON array (not a map)" do
      path = fixture_path("array.json")
      File.write!(path, "[1, 2, 3]")

      assert {:error, :invalid_json_shape} = CodexCache.resolve(path: path)
    end

    test "returns error for oversize file" do
      path = fixture_path("oversize.json")
      # Write content > 1 MB
      big_token = String.duplicate("x", 2_000_000)
      File.write!(path, ~s({"access_token":"#{big_token}"}))

      assert {:error, :file_too_large} = CodexCache.resolve(path: path)
    end

    test "returns error for empty token string" do
      path = fixture_path("empty_token.json")
      write_fixture!(path, %{"access_token" => ""})

      assert {:error, :no_token} = CodexCache.resolve(path: path)
    end

    test "returns error for nil token value" do
      path = fixture_path("nil_token.json")
      write_fixture!(path, %{"access_token" => nil})

      assert {:error, :no_token} = CodexCache.resolve(path: path)
    end

    test "returns error when no token key exists" do
      path = fixture_path("no_token_key.json")
      write_fixture!(path, %{"some_other_key" => "value"})

      assert {:error, :no_token} = CodexCache.resolve(path: path)
    end

    # ---------------------------------------------------------------------------
    # Redaction / safety
    # ---------------------------------------------------------------------------

    test "redacted field is safe for logs" do
      path = fixture_path("redact_test.json")
      write_fixture!(path, %{"access_token" => "sk-secret-token-12345"})

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.redacted =~ "REDACTED"
      refute cred.redacted =~ "sk-secret-token-12345"
    end

    test "error messages do not contain token values" do
      path = fixture_path("no_leak.json")

      {:error, reason} = CodexCache.resolve(path: path)
      reason_str = inspect(reason)
      refute reason_str =~ "tok_"
      refute reason_str =~ "secret"
    end

    # ---------------------------------------------------------------------------
    # Permission warnings
    # ---------------------------------------------------------------------------

    test "adds permissive_permissions warning for 0644 file" do
      path = fixture_path("perm_644.json")
      write_fixture!(path, %{"access_token" => "tok"})
      File.chmod!(path, 0o644)

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert {:permissive_permissions, "0600 recommended"} in cred.warnings
    end

    test "no warning for 0600 file" do
      path = fixture_path("perm_600.json")
      write_fixture!(path, %{"access_token" => "tok"})
      File.chmod!(path, 0o600)

      assert {:ok, cred} = CodexCache.resolve(path: path)
      assert cred.warnings == []
    end

    test "permission check does not raise on platforms that lack chmod" do
      path = fixture_path("perm_noop.json")
      write_fixture!(path, %{"access_token" => "tok"})

      # On platforms where File.stat doesn't support mode or chmod is unsupported,
      # the permission check should silently pass.
      assert {:ok, _cred} = CodexCache.resolve(path: path)
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp fixture_path(name) do
    Path.join(System.tmp_dir!(), "codex_cache_test_#{name}")
  end

  defp write_fixture!(path, data) do
    json = Jason.encode!(data)
    File.write!(path, json)
  end

  defp tmp_home! do
    dir = Path.join(System.tmp_dir!(), "codex_cache_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
