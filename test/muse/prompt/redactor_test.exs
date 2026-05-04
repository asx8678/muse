defmodule Muse.Prompt.RedactorTest do
  use ExUnit.Case, async: true

  alias Muse.Prompt.Redactor

  describe "redact_text/1" do
    test "redacts sk- API keys" do
      assert Redactor.redact_text("my key is sk-test-12345") =~ "[REDACTED]"
      refute Redactor.redact_text("my key is sk-test-12345") =~ "sk-test-12345"
    end

    test "redacts Bearer tokens" do
      assert Redactor.redact_text("Authorization: Bearer abc123xyz") =~ "[REDACTED]"
      refute Redactor.redact_text("Authorization: Bearer abc123xyz") =~ "abc123xyz"
    end

    test "redacts .env assignments" do
      result = Redactor.redact_text("DATABASE_URL=postgres://user:pass@host/db")
      assert result =~ "[REDACTED]"
      refute result =~ "postgres://user:pass@host/db"
    end

    test "redacts SECRET_KEY assignments" do
      result = Redactor.redact_text("SECRET_KEY=my_super_secret_value_12345")
      assert result =~ "[REDACTED]"
    end

    test "redacts API_KEY assignments" do
      result = Redactor.redact_text("API_KEY=abc123def456")
      assert result =~ "[REDACTED]"
    end

    test "redacts private key blocks" do
      text = """
      Here is my key:
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEA1234567890
      -----END RSA PRIVATE KEY-----
      That was my key.
      """

      result = Redactor.redact_text(text)
      assert result =~ "[REDACTED]"
      refute result =~ "MIIEowIBAAKCAQEA1234567890"
    end

    test "redacts JWT tokens" do
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123def456ghi789"
      result = Redactor.redact_text("Token: #{jwt}")
      assert result =~ "[REDACTED]"
      refute result =~ "eyJhbGciOiJIUzI1NiJ9"
    end

    test "redacts X-Api-Key headers" do
      result = Redactor.redact_text("X-Api-Key: my-secret-key-12345")
      assert result =~ "[REDACTED]"
      refute result =~ "my-secret-key-12345"
    end

    test "redacts embedded URL credentials" do
      result = Redactor.redact_text("https://admin:password123@internal.host/api")
      assert result =~ "[REDACTED]"
      refute result =~ "admin:password123"
    end

    test "redacts Codex auth tokens" do
      result = Redactor.redact_text(~s(codex_auth_token="abc123longtokenvalue"))
      assert result =~ "[REDACTED]"
    end

    test "preserves non-secret text" do
      text = "This is a safe message with no secrets."
      assert Redactor.redact_text(text) == text
    end
  end

  describe "redact_term/1" do
    test "redacts secrets in nested maps" do
      term = %{config: %{api_key: "sk-live-abc123def456ghi789"}}
      result = Redactor.redact_term(term)
      assert result.config.api_key == "[REDACTED]"
    end

    test "redacts secrets in lists" do
      term = ["key=sk-test-123", "safe text"]
      result = Redactor.redact_term(term)
      assert hd(result) =~ "[REDACTED]"
    end

    test "preserves non-secret values in maps" do
      term = %{name: "Planning Muse", count: 3}
      result = Redactor.redact_term(term)
      assert result.name == "Planning Muse"
      assert result.count == 3
    end

    test "redacts prompt-specific patterns in struct string fields" do
      # ArgumentError is a struct with a :message field
      term = %ArgumentError{message: "DATABASE_URL=postgres://user:pass@host/db"}
      result = Redactor.redact_term(term)
      assert result.message =~ "[REDACTED]"
      refute result.message =~ "postgres://user:pass@host/db"
    end

    test "redacts URL credentials in struct fields" do
      term = %ArgumentError{message: "connect to https://admin:secret123@internal.host/api"}
      result = Redactor.redact_term(term)
      refute result.message =~ "admin:secret123"
      assert result.message =~ "[REDACTED]"
    end

    test "preserves non-secret struct fields" do
      term = %ArgumentError{message: "something went wrong safely"}
      result = Redactor.redact_term(term)
      assert result.message == "something went wrong safely"
      assert %ArgumentError{} = result
    end
  end

  describe "preview_text/2" do
    test "redacts before truncation" do
      # Short text with secret — redaction should happen before truncation
      text = "config: DATABASE_URL=secret_db_url_value"
      result = Redactor.preview_text(text, max_length: 200)
      assert result =~ "[REDACTED]"
      refute result =~ "secret_db_url_value"
    end

    test "truncates long safe text" do
      long_text = String.duplicate("A", 600)
      result = Redactor.preview_text(long_text, max_length: 100)
      assert String.length(result) <= 110
      assert String.ends_with?(result, "\u2026") or String.length(result) <= 100
    end

    test "does not truncate short text" do
      text = "Hello, safe world."
      result = Redactor.preview_text(text, max_length: 500)
      assert result == text
    end

    test "default max_length is 500" do
      text = String.duplicate("X", 499)
      result = Redactor.preview_text(text)
      refute String.ends_with?(result, "…")
    end
  end

  describe "comprehensive secret coverage" do
    test "redacts PASSWORD assignments" do
      result = Redactor.redact_text("PASSWORD=hunter2admin")
      assert result =~ "[REDACTED]"
    end

    test "redacts ENCRYPTION_KEY assignments" do
      result = Redactor.redact_text("ENCRYPTION_KEY=aes256secretkeyvalue")
      assert result =~ "[REDACTED]"
    end

    test "redacts X-Auth-Token headers" do
      result = Redactor.redact_text("X-Auth-Token: abc123def456ghi789jkl")
      assert result =~ "[REDACTED]"
    end

    test "redacts long opaque token-like values after token/key/secret keywords" do
      token_value = String.duplicate("a", 40)
      result = Redactor.redact_text("token=\"#{token_value}\"")
      assert result =~ "[REDACTED]"
    end

    test "redacts BEGIN CERTIFICATE blocks" do
      text = """
      -----BEGIN CERTIFICATE-----
      MIIDddCCB12gAwIBAgIEU
      -----END CERTIFICATE-----
      """

      result = Redactor.redact_text(text)
      assert result =~ "[REDACTED]"
    end
  end
end
