defmodule Muse.EventPayloadRedactorTest do
  use ExUnit.Case, async: true

  alias Muse.EventPayloadRedactor

  # -- Sensitive key redaction --------------------------------------------------

  describe "redact/1 — sensitive key redaction" do
    test "redacts values under sensitive keys" do
      data = %{api_key: "sk-secret-123", name: "visible"}
      result = EventPayloadRedactor.redact(data)
      assert result.api_key == "[REDACTED]"
      assert result.name == "visible"
    end

    test "redacts case-insensitively" do
      data = %{"Password" => "hunter2", "TOKEN" => "abc"}
      result = EventPayloadRedactor.redact(data)
      assert result["Password"] == "[REDACTED]"
      assert result["TOKEN"] == "[REDACTED]"
    end

    test "redacts nested sensitive keys" do
      data = %{config: %{secret: "shhh", safe: "ok"}}
      result = EventPayloadRedactor.redact(data)
      assert result.config.secret == "[REDACTED]"
      assert result.config.safe == "ok"
    end
  end

  # -- Secret string pattern redaction ------------------------------------------

  describe "redact/1 — secret string patterns" do
    test "redacts sk- prefixed API keys in text" do
      data = %{text: "my key is sk-test-12345 and that is it"}
      result = EventPayloadRedactor.redact(data)
      assert result.text =~ "[REDACTED]"
      refute result.text =~ "sk-test-12345"
    end

    test "redacts Bearer tokens in text" do
      data = %{text: "Authorization: Bearer secret-token-here"}
      result = EventPayloadRedactor.redact(data)
      assert result.text =~ "[REDACTED]"
      refute result.text =~ "secret-token-here"
    end

    test "redacts api_key= in text" do
      data = %{text: "curl -d 'api_key=sk-proj-abc123'"}
      result = EventPayloadRedactor.redact(data)
      assert result.text =~ "[REDACTED]"
      refute result.text =~ "sk-proj-abc123"
    end

    test "redacts token= in text" do
      data = %{text: "https://example.com?token=abc123def"}
      result = EventPayloadRedactor.redact(data)
      assert result.text =~ "[REDACTED]"
      refute result.text =~ "abc123def"
    end

    test "preserves non-secret text" do
      data = %{text: "Hello, this is a normal message"}
      result = EventPayloadRedactor.redact(data)
      assert result.text == "Hello, this is a normal message"
    end
  end

  # -- Recursive redaction -------------------------------------------------------

  describe "redact/1 — recursive" do
    test "redacts inside lists" do
      data = %{messages: [%{text: "key=sk-test-123"}, %{text: "safe"}]}
      result = EventPayloadRedactor.redact(data)
      assert length(result.messages) == 2
      assert result.messages |> Enum.at(0) |> Map.get(:text) =~ "[REDACTED]"
      assert result.messages |> Enum.at(1) |> Map.get(:text) == "safe"
    end

    test "redacts sensitive keys inside lists" do
      data = %{items: [%{token: "abc", name: "ok"}]}
      result = EventPayloadRedactor.redact(data)
      assert result.items |> Enum.at(0) |> Map.get(:token) == "[REDACTED]"
      assert result.items |> Enum.at(0) |> Map.get(:name) == "ok"
    end

    test "passes through primitives unchanged" do
      assert EventPayloadRedactor.redact(42) == 42
      assert EventPayloadRedactor.redact(true) == true
      assert EventPayloadRedactor.redact(nil) == nil
      assert EventPayloadRedactor.redact(3.14) == 3.14
    end
  end

  # -- redact_string/1 ----------------------------------------------------------

  describe "redact_string/1" do
    test "redacts sk- prefixed strings" do
      result = EventPayloadRedactor.redact_string("key=sk-test-12345")
      assert result =~ "[REDACTED]"
      refute result =~ "sk-test-12345"
    end

    test "redacts Bearer tokens" do
      result = EventPayloadRedactor.redact_string("Bearer my-secret-token")
      assert result =~ "[REDACTED]"
      refute result =~ "my-secret-token"
    end

    test "redacts OAuth and Codex-looking tokens" do
      text =
        "oauth_token=ya29.oauth-secret codex_auth_token=codex-secret gho_abcdefghijklmnopqrstuvwxyz123456"

      result = EventPayloadRedactor.redact_string(text)

      assert result =~ "[REDACTED]"
      refute result =~ "ya29.oauth-secret"
      refute result =~ "codex-secret"
      refute result =~ "gho_abcdefghijklmnopqrstuvwxyz123456"
    end

    test "preserves safe strings" do
      result = EventPayloadRedactor.redact_string("Hello world")
      assert result == "Hello world"
    end
  end

  # -- Integration with Event creation -------------------------------------------

  describe "redaction in Event.new/4 data" do
    test "redacted data does not contain secrets when used with Event.new" do
      safe_data =
        EventPayloadRedactor.redact(%{
          text: "my api key is sk-test-12345",
          metadata: %{token: "secret-val"}
        })

      event =
        Muse.Event.new(:cli, :user_message, safe_data, session_id: "test", visibility: :user)

      # Sensitive key values are redacted
      assert event.data.metadata.token == "[REDACTED]"
      # Secret patterns in text are redacted
      refute event.data.text =~ "sk-test-12345"
      assert event.data.text =~ "[REDACTED]"
    end
  end
end
