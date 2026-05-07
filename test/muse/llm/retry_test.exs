defmodule Muse.LLM.RetryTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.Retry

  describe "with_retry/2 — success path" do
    test "returns success immediately on first attempt" do
      result = Retry.with_retry(fn -> {:ok, "success"} end, max_retries: 3)
      assert result == {:ok, "success"}
    end

    test "returns success after retrying transient error" do
      attempts = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(attempts, 1, 1)
            count = :counters.get(attempts, 1)

            if count == 1 do
              {:error, :timeout}
            else
              {:ok, "recovered"}
            end
          end,
          max_retries: 2,
          backoff_fn: fn _attempt, _opts -> 0 end
        )

      assert result == {:ok, "recovered"}
      assert :counters.get(attempts, 1) == 2
    end
  end

  describe "with_retry/2 — non-retryable errors" do
    test "does not retry auth errors" do
      attempts = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(attempts, 1, 1)
            {:error, {:http_error, 401, "Unauthorized"}}
          end,
          max_retries: 3,
          backoff_fn: fn _attempt, _opts -> 0 end
        )

      assert match?({:error, _}, result)
      # Only called once — auth errors are not retried
      assert :counters.get(attempts, 1) == 1
    end

    test "does not retry invalid model errors" do
      attempts = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(attempts, 1, 1)
            {:error, {:http_error, 404, "Not found"}}
          end,
          max_retries: 3,
          backoff_fn: fn _attempt, _opts -> 0 end
        )

      assert match?({:error, _}, result)
      assert :counters.get(attempts, 1) == 1
    end

    test "does not retry with max_retries: 0" do
      attempts = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(attempts, 1, 1)
            {:error, :timeout}
          end,
          max_retries: 0,
          backoff_fn: fn _attempt, _opts -> 0 end
        )

      assert match?({:error, _}, result)
      assert :counters.get(attempts, 1) == 1
    end
  end

  describe "with_retry/2 — retryable errors exhausted" do
    test "returns error after max retries exhausted" do
      attempts = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(attempts, 1, 1)
            {:error, :timeout}
          end,
          max_retries: 2,
          backoff_fn: fn _attempt, _opts -> 0 end
        )

      assert match?({:error, :timeout}, result)
      # Initial call + 2 retries = 3 total
      assert :counters.get(attempts, 1) == 3
    end

    test "stops retrying when error becomes non-retryable" do
      attempts = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(attempts, 1, 1)
            count = :counters.get(attempts, 1)

            if count == 1 do
              {:error, :timeout}
            else
              {:error, {:http_error, 401, "Unauthorized"}}
            end
          end,
          max_retries: 3,
          backoff_fn: fn _attempt, _opts -> 0 end
        )

      assert match?({:error, _}, result)
      # First call (timeout) + retry (auth error) = 2
      assert :counters.get(attempts, 1) == 2
    end
  end

  describe "with_retry/2 — backoff" do
    test "uses custom backoff function" do
      backoff_calls = :counters.new(1, [:atomics])

      backoff_fn = fn attempt, _opts ->
        :counters.add(backoff_calls, 1, 1)
        # No actual delay for tests
        0
      end

      result =
        Retry.with_retry(
          fn -> {:error, :timeout} end,
          max_retries: 2,
          backoff_fn: backoff_fn
        )

      assert match?({:error, _}, result)
      # Should have been called once for the first retry
      assert :counters.get(backoff_calls, 1) >= 1
    end

    test "calls on_retry callback" do
      retries = :counters.new(1, [:atomics])

      on_retry = fn _attempt, _error ->
        :counters.add(retries, 1, 1)
        :ok
      end

      Retry.with_retry(
        fn -> {:error, :timeout} end,
        max_retries: 2,
        backoff_fn: fn _attempt, _opts -> 0 end,
        on_retry: on_retry
      )

      # on_retry should have been called for each retry attempt
      assert :counters.get(retries, 1) >= 1
    end
  end

  describe "compute_delay/2" do
    test "first attempt delay is approximately base_delay_ms" do
      delay = Retry.compute_delay(1, base_delay_ms: 1000, multiplier: 2, max_delay_ms: 30_000)
      # With ±20% jitter, should be between 800 and 1200
      assert delay >= 800 and delay <= 1200
    end

    test "second attempt delay is approximately base * multiplier" do
      delay = Retry.compute_delay(2, base_delay_ms: 1000, multiplier: 2, max_delay_ms: 30_000)
      # 2000ms ± 20% = 1600 to 2400
      assert delay >= 1600 and delay <= 2400
    end

    test "delay is capped by max_delay_ms" do
      delay = Retry.compute_delay(10, base_delay_ms: 1000, multiplier: 2, max_delay_ms: 5000)
      # Even at attempt 10 (would be 512000ms without cap), it should be ≤ 6000 (5000 + 20%)
      assert delay <= 6000
    end

    test "delay is never negative" do
      for attempt <- 1..10 do
        delay =
          Retry.compute_delay(attempt, base_delay_ms: 1000, multiplier: 2, max_delay_ms: 30_000)

        assert delay >= 0
      end
    end

    test "zero base delay produces zero delay" do
      delay = Retry.compute_delay(1, base_delay_ms: 0, multiplier: 2, max_delay_ms: 30_000)
      assert delay == 0
    end
  end

  describe "retryable?/1" do
    test "timeout is retryable" do
      assert Retry.retryable?(:timeout) == true
    end

    test "HTTP 429 is retryable" do
      assert Retry.retryable?({:http_error, 429, "Rate limited"}) == true
    end

    test "HTTP 500 is retryable" do
      assert Retry.retryable?({:http_error, 500, "Server error"}) == true
    end

    test "HTTP 401 is not retryable" do
      assert Retry.retryable?({:http_error, 401, "Unauthorized"}) == false
    end

    test "HTTP 404 is not retryable" do
      assert Retry.retryable?({:http_error, 404, "Not found"}) == false
    end
  end
end
