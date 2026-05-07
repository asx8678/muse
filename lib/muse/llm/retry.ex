defmodule Muse.LLM.Retry do
  @moduledoc """
  Bounded retry with exponential backoff for transient provider failures.

  Only retries errors classified as retryable by `Muse.LLM.ProviderError`.
  Client errors (auth, invalid model, invalid request) are never retried —
  retrying would produce the same failure.

  ## Backoff strategy

    * Base delay: 1000ms (1 second)
    * Multiplier: 2 (exponential)
    * Max delay: 30_000ms (30 seconds)
    * Jitter: ±20% of computed delay (prevents thundering herd)
    * Max retries: from `ProviderConfig.max_retries` (default: 2)

  ## Safety

    * No infinite retries — bounded by `max_retries` from config.
    * No secrets in logs — all error logging uses redacted error data.
    * Deterministic for testing — inject `:backoff_fn` and `:now_fn` opts.
    * Only retries transient errors (5xx, timeouts, connection errors, 429).

  ## Usage

      opts = [max_retries: 2]
      result = Muse.LLM.Retry.with_retry(fn ->
        MyProvider.stream(request, emit)
      end, opts)
  """

  alias Muse.LLM.ProviderError

  @default_base_delay_ms 1000
  @default_multiplier 2
  @default_max_delay_ms 30_000
  @default_max_retries 2

  @type retry_opts :: [
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          multiplier: pos_integer(),
          max_delay_ms: pos_integer(),
          backoff_fn: (non_neg_integer(), keyword() -> non_neg_integer()),
          now_fn: (-> integer()),
          on_retry: (non_neg_integer(), ProviderError.t() -> :ok)
        ]

  @type retry_result :: {:ok, term()} | {:error, term()}

  @doc """
  Execute a function with retry on transient failures.

  Returns `{:ok, result}` on success, or `{:error, reason}` when all retries
  are exhausted or the error is non-retryable.

  ## Options

    * `:max_retries` — maximum number of retry attempts (default: 2, 0 = no retry)
    * `:base_delay_ms` — initial delay in ms (default: 1000)
    * `:multiplier` — exponential backoff multiplier (default: 2)
    * `:max_delay_ms` — maximum delay cap in ms (default: 30_000)
    * `:backoff_fn` — custom backoff function `(attempt, opts) -> delay_ms`
    * `:now_fn` — custom time function for testing (default: `System.monotonic_time/1`)
    * `:on_retry` — callback invoked before each retry `(attempt, error) -> :ok`

  ## Examples

      iex> Muse.LLM.Retry.with_retry(fn -> {:ok, "success"} end, max_retries: 2)
      {:ok, "success"}

      iex> Muse.LLM.Retry.with_retry(fn -> {:error, :timeout} end, max_retries: 0)
      {:error, :timeout}
  """
  @spec with_retry((-> retry_result()), retry_opts()) :: retry_result()
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)

    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        error = ProviderError.classify(reason)

        if error.retryable and max_retries > 0 do
          retry_loop(fun, error, 1, max_retries, opts)
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Compute the backoff delay for a given attempt number.

  Uses exponential backoff with jitter. The delay for attempt `n` is:

      delay = min(base * multiplier^(n-1), max_delay)
      jitter = delay * random(-0.2, 0.2)
      final = max(0, delay + jitter)

  For deterministic testing, pass `:backoff_fn` to `with_retry/2`.

  ## Examples

      iex> delay = Muse.LLM.Retry.compute_delay(1, base_delay_ms: 1000, multiplier: 2, max_delay_ms: 30_000)
      iex> is_integer(delay) and delay >= 800 and delay <= 1200
      true

      iex> delay = Muse.LLM.Retry.compute_delay(2, base_delay_ms: 1000, multiplier: 2, max_delay_ms: 30_000)
      iex> is_integer(delay) and delay >= 1600 and delay <= 2400
      true
  """
  @spec compute_delay(non_neg_integer(), keyword()) :: non_neg_integer()
  def compute_delay(attempt, opts \\ []) when is_integer(attempt) and attempt >= 1 do
    base = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    multiplier = Keyword.get(opts, :multiplier, @default_multiplier)
    max_delay = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)

    # Exponential: base * multiplier^(attempt - 1)
    raw_delay = base * :math.pow(multiplier, attempt - 1)
    capped = min(raw_delay, max_delay)

    # Add ±20% jitter to prevent thundering herd
    jitter_range = capped * 0.2
    jitter = :rand.uniform() * jitter_range * 2 - jitter_range

    delay = round(capped + jitter)
    max(0, delay)
  end

  @doc """
  Return whether a given error is retryable.

  Delegates to `ProviderError.retryable?/1`.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(error) do
    error
    |> ProviderError.classify()
    |> Map.get(:retryable, false)
  end

  # -- Private ----------------------------------------------------------------

  defp retry_loop(_fun, prev_error, attempt, max_retries, _opts) when attempt > max_retries do
    # All retries exhausted — return the last error
    {:error, prev_error}
  end

  defp retry_loop(fun, _prev_error, attempt, max_retries, opts) do
    backoff_fn = Keyword.get(opts, :backoff_fn, &compute_delay/2)
    on_retry = Keyword.get(opts, :on_retry, &default_on_retry/2)

    delay = backoff_fn.(attempt, opts)

    # Sleep for backoff
    if delay > 0 do
      sleep_with_fn(delay, Keyword.get(opts, :sleep_fn, &Process.sleep/1))
    end

    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        error = ProviderError.classify(reason)

        # Notify about retry
        on_retry.(attempt, error)

        if error.retryable do
          retry_loop(fun, reason, attempt + 1, max_retries, opts)
        else
          # Non-retryable error — stop immediately
          {:error, reason}
        end
    end
  end

  defp default_on_retry(_attempt, _error) do
    # Default retry notification — no-op. In production, callers can wire
    # this to telemetry or diagnostics.
    :ok
  end

  defp sleep_with_fn(delay, sleep_fn) when is_integer(delay) and delay > 0 do
    sleep_fn.(delay)
  end

  defp sleep_with_fn(_delay, _sleep_fn), do: :ok
end
