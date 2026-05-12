defmodule Muse.LLM.ProviderErrorTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.ProviderError

  describe "classify/1 — HTTP errors" do
    test "classifies 401 as auth error" do
      error = ProviderError.classify({:http_error, 401, "Unauthorized"})
      assert error.category == :auth
      assert error.retryable == false
      assert error.http_status == 401
    end

    test "classifies 403 as auth error" do
      error = ProviderError.classify({:http_error, 403, "Forbidden"})
      assert error.category == :auth
      assert error.retryable == false
      assert error.http_status == 403
    end

    test "classifies 429 as rate limit error (retryable)" do
      error = ProviderError.classify({:http_error, 429, "Rate limited"})
      assert error.category == :rate_limit
      assert error.retryable == true
      assert error.http_status == 429
    end

    test "classifies 404 as invalid model error" do
      error = ProviderError.classify({:http_error, 404, "Not found"})
      assert error.category == :invalid_model
      assert error.retryable == false
    end

    test "classifies 400 as invalid request error" do
      error = ProviderError.classify({:http_error, 400, "Bad request"})
      assert error.category == :invalid_request
      assert error.retryable == false
    end

    test "classifies 402 as quota error" do
      error = ProviderError.classify({:http_error, 402, "Payment required"})
      assert error.category == :quota
      assert error.retryable == false
    end

    test "classifies 500 as server error (retryable)" do
      error = ProviderError.classify({:http_error, 500, "Internal server error"})
      assert error.category == :server
      assert error.retryable == true
    end

    test "classifies 502 as server error (retryable)" do
      error = ProviderError.classify({:http_error, 502, "Bad gateway"})
      assert error.category == :server
      assert error.retryable == true
    end

    test "classifies 503 as server error (retryable)" do
      error = ProviderError.classify({:http_error, 503, "Service unavailable"})
      assert error.category == :server
      assert error.retryable == true
    end

    test "classifies unknown HTTP status as unknown" do
      error = ProviderError.classify({:http_error, 418, "I'm a teapot"})
      assert error.category == :unknown
      assert error.retryable == false
    end

    test "classifies provider adapter HTTP error shapes" do
      error =
        ProviderError.classify(
          {:provider_http_error, %{status: 401, body_summary: "Unauthorized"}}
        )

      assert error.category == :auth
      assert error.retryable == false
      assert error.http_status == 401
    end
  end

  describe "classify/1 — non-HTTP errors" do
    test "classifies :timeout" do
      error = ProviderError.classify(:timeout)
      assert error.category == :timeout
      assert error.retryable == true
    end

    test "classifies {:timeout, ms}" do
      error = ProviderError.classify({:timeout, 30000})
      assert error.category == :timeout
      assert error.retryable == true
    end

    test "classifies {:connection_error, _}" do
      error = ProviderError.classify({:connection_error, "ECONNREFUSED"})
      assert error.category == :connection
      assert error.retryable == true
    end

    test "classifies {:econnrefused, _}" do
      error = ProviderError.classify({:econnrefused, :localhost})
      assert error.category == :connection
      assert error.retryable == true
    end

    test "classifies {:context_length_exceeded, _}" do
      error = ProviderError.classify({:context_length_exceeded, "too many tokens"})
      assert error.category == :context_length
      assert error.retryable == false
    end

    test "classifies {:rate_limit, _}" do
      error = ProviderError.classify({:rate_limit, "slow down"})
      assert error.category == :rate_limit
      assert error.retryable == true
    end

    test "classifies {:auth_error, reason}" do
      error = ProviderError.classify({:auth_error, "invalid API key"})
      assert error.category == :auth
      assert error.retryable == false
    end

    test "classifies {:invalid_model, reason}" do
      error = ProviderError.classify({:invalid_model, "model xyz not found"})
      assert error.category == :invalid_model
      assert error.retryable == false
    end

    test "classifies {:server_error, status, reason}" do
      error = ProviderError.classify({:server_error, 500, "internal error"})
      assert error.category == :server
      assert error.retryable == true
      assert error.http_status == 500
    end

    test "classifies :closed as connection error" do
      error = ProviderError.classify(:closed)
      assert error.category == :connection
      assert error.retryable == true
    end

    test "classifies provider adapter network errors as retryable" do
      error = ProviderError.classify({:provider_network_error, %{reason: "Connection refused"}})
      assert error.category == :connection
      assert error.retryable == true
    end

    test "classifies provider adapter timeout summaries as timeout" do
      error = ProviderError.classify({:provider_network_error, %{reason: "request timeout"}})
      assert error.category == :timeout
      assert error.retryable == true
    end
  end

  describe "classify/1 — string pattern matching" do
    test "classifies string with 'unauthorized' as auth" do
      error = ProviderError.classify("401 Unauthorized: invalid api key sk-12345")
      assert error.category == :auth
    end

    test "classifies string with 'rate limit' as rate_limit" do
      error = ProviderError.classify("Rate limit exceeded for model gpt-4")
      assert error.category == :rate_limit
      assert error.retryable == true
    end

    test "classifies string with 'not found' as invalid_model" do
      error = ProviderError.classify("Model not found: gpt-5")
      assert error.category == :invalid_model
    end

    test "classifies string with 'timeout' as timeout" do
      error = ProviderError.classify("Request timeout after 30000ms")
      assert error.category == :timeout
      assert error.retryable == true
    end

    test "classifies string with 'connection' as connection" do
      error = ProviderError.classify("Connection refused to api.openai.com")
      assert error.category == :connection
    end

    test "classifies string with 'context length' as context_length" do
      error = ProviderError.classify("Context length exceeded maximum tokens")
      assert error.category == :context_length
    end

    test "classifies unknown string as unknown" do
      error = ProviderError.classify("Some random error message")
      assert error.category == :unknown
    end
  end

  describe "classify/1 — secret safety" do
    test "raw error field is redacted and doesn't contain secrets" do
      error = ProviderError.classify({:auth_error, "API key sk-test-1234567890abcdef is invalid"})
      # The raw field should be redacted
      refute String.contains?(to_string(error.raw), "sk-test-1234567890abcdef")
    end

    test "message field doesn't contain secrets" do
      error = ProviderError.classify({:http_error, 401, "sk-test-secret-key-12345"})
      refute String.contains?(error.message, "sk-test-secret-key-12345")
    end

    test "hint field doesn't contain secrets" do
      error = ProviderError.classify({:http_error, 401, "sk-test-key"})
      refute String.contains?(error.hint, "sk-test-key")
    end
  end

  describe "render/1" do
    test "renders auth error with hint" do
      error = ProviderError.classify({:http_error, 401, "Unauthorized"})
      output = ProviderError.render(error)

      assert output =~ "Authentication failed"
      assert output =~ "/auth status"
    end

    test "renders rate limit error with retry suggestion" do
      error = ProviderError.classify({:http_error, 429, "Rate limited"})
      output = ProviderError.render(error)

      assert output =~ "Rate limited"
      assert output =~ "retry" or output =~ "Retry"
    end

    test "renders timeout error with hint" do
      error = ProviderError.classify(:timeout)
      output = ProviderError.render(error)

      assert output =~ "timed out"
      assert output =~ "MUSE_LLM_TIMEOUT_MS"
    end

    test "renders compact summary" do
      error = ProviderError.classify({:http_error, 401, "Unauthorized"})
      compact = ProviderError.render_compact(error)

      assert compact =~ "Authentication failed"
      assert compact =~ "/auth status"
    end
  end

  describe "retryable?/1" do
    test "rate_limit is retryable" do
      assert ProviderError.retryable?(:rate_limit) == true
    end

    test "timeout is retryable" do
      assert ProviderError.retryable?(:timeout) == true
    end

    test "connection is retryable" do
      assert ProviderError.retryable?(:connection) == true
    end

    test "server is retryable" do
      assert ProviderError.retryable?(:server) == true
    end

    test "auth is not retryable" do
      assert ProviderError.retryable?(:auth) == false
    end

    test "invalid_model is not retryable" do
      assert ProviderError.retryable?(:invalid_model) == false
    end

    test "invalid_request is not retryable" do
      assert ProviderError.retryable?(:invalid_request) == false
    end

    test "unknown is not retryable" do
      assert ProviderError.retryable?(:unknown) == false
    end
  end

  describe "categories/0 and retryable_categories/0" do
    test "categories returns all categories" do
      cats = ProviderError.categories()
      assert :auth in cats
      assert :rate_limit in cats
      assert :timeout in cats
      assert :connection in cats
      assert :server in cats
      assert :invalid_model in cats
      assert :invalid_request in cats
      assert :quota in cats
      assert :context_length in cats
      assert :unknown in cats
    end

    test "retryable_categories returns only retryable ones" do
      retryable = ProviderError.retryable_categories()
      assert retryable == [:rate_limit, :timeout, :connection, :server]
    end
  end

  describe "classify/1 — retries exhausted" do
    test "classifies {:retries_exhausted, :timeout, N} with retry context" do
      error = ProviderError.classify({:retries_exhausted, :timeout, 2})

      assert error.category == :timeout
      assert error.title =~ "timed out"
      assert error.title =~ "retries exhausted"
      assert error.message =~ "2 retry attempt(s) failed"
      assert is_binary(error.hint)
    end

    test "classifies {:retries_exhausted, {:http_error, 429, _}, N} as rate_limit" do
      error = ProviderError.classify({:retries_exhausted, {:http_error, 429, "limited"}, 3})

      assert error.category == :rate_limit
      assert error.title =~ "Rate limited"
      assert error.title =~ "retries exhausted"
      assert error.message =~ "3 retry attempt(s) failed"
    end

    test "classifies {:retries_exhausted, {:connection_error, _}, N} as connection" do
      error = ProviderError.classify({:retries_exhausted, {:connection_error, "refused"}, 1})

      assert error.category == :connection
      assert error.title =~ "Connection error"
      assert error.title =~ "retries exhausted"
    end

    test "classifies {:retries_exhausted, {:http_error, 503, _}, N} as server" do
      error = ProviderError.classify({:retries_exhausted, {:http_error, 503, "overloaded"}, 2})

      assert error.category == :server
      assert error.title =~ "Server error"
      assert error.title =~ "retries exhausted"
    end

    test "render includes hint for retries exhausted" do
      error = ProviderError.classify({:retries_exhausted, :timeout, 2})
      rendered = ProviderError.render(error)

      assert rendered =~ "💡"
      assert rendered =~ "retries exhausted"
    end

    test "never includes secrets in retries exhausted output" do
      error =
        ProviderError.classify({:retries_exhausted, {:http_error, 429, "sk-secret-key-12345"}, 2})

      refute ProviderError.render(error) =~ "sk-secret-key-12345"
      refute ProviderError.render_compact(error) =~ "sk-secret-key-12345"
    end
  end
end
