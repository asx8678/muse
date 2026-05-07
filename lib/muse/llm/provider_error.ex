defmodule Muse.LLM.ProviderError do
  @moduledoc """
  Maps provider errors to user-friendly, actionable messages.

  Every error is classified into a category, and the corresponding message
  includes a concrete suggestion for what the user should do next.

  ## Safety

    * Error messages are always secret-safe — they never contain API keys,
      bearer tokens, or other sensitive values.
    * Raw error terms from providers are redacted before inclusion in any
      user-facing output.
    * Stack traces are never shown to users.

  ## Error categories

    * `:auth`            — 401/403 authentication/authorization failures
    * `:rate_limit`      — 429 rate limiting (retryable with backoff)
    * `:invalid_model`   — model not found or not accessible (404)
    * `:invalid_request` — 400 bad request (payload issue)
    * `:timeout`          — request timed out
    * `:connection`       — network/connection error
    * `:server`           — 5xx server error (retryable)
    * `:quota`            — account/quota exceeded
    * `:context_length`   — prompt exceeds model context window
    * `:unknown`          — unclassifiable error

  ## Retry classification

  `retryable?/1` returns `true` for errors where a retry with backoff
  may succeed: rate limits, timeouts, connection errors, and server errors.
  Client errors (auth, invalid model, invalid request) are never retried.
  """

  alias Muse.Prompt.Redactor

  @type category ::
          :auth
          | :rate_limit
          | :invalid_model
          | :invalid_request
          | :timeout
          | :connection
          | :server
          | :quota
          | :context_length
          | :unknown

  @type t :: %__MODULE__{
          category: category(),
          title: String.t(),
          message: String.t(),
          hint: String.t(),
          retryable: boolean(),
          raw: term() | nil,
          http_status: pos_integer() | nil
        }

  defstruct [
    :category,
    :title,
    :message,
    :hint,
    :retryable,
    :raw,
    :http_status
  ]

  @doc """
  Classify a provider error into a structured, actionable error report.

  Accepts raw error terms from provider adapters and produces a safe,
  user-facing error with category, message, and hint.

  ## Examples

      iex> error = Muse.LLM.ProviderError.classify({:http_error, 401, "Unauthorized"})
      iex> error.category
      :auth

      iex> error = Muse.LLM.ProviderError.classify({:http_error, 429, "Rate limited"})
      iex> error.retryable
      true

      iex> error = Muse.LLM.ProviderError.classify(:timeout)
      iex> error.category
      :timeout
  """
  @spec classify(term()) :: t()
  def classify(error) do
    {category, title, message, hint, retryable, http_status} = do_classify(error)

    %__MODULE__{
      category: category,
      title: title,
      message: message,
      hint: hint,
      retryable: retryable,
      raw: redact_raw(error),
      http_status: http_status
    }
  end

  @doc """
  Render a provider error as a human-readable, multi-line string.

  All output is secret-safe.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = error) do
    lines = [
      "⚠  #{error.title}",
      "",
      error.message
    ]

    lines =
      if error.hint do
        lines ++ ["", "💡 #{error.hint}"]
      else
        lines
      end

    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Render a compact one-line error summary.
  """
  @spec render_compact(t()) :: String.t()
  def render_compact(%__MODULE__{} = error) do
    if error.hint do
      "#{error.title} — #{error.hint}"
    else
      error.title
    end
  end

  @doc """
  Return whether an error category is retryable.

  Only transient errors (rate limits, timeouts, connection errors, server
  errors) are retryable.  Client errors (auth, invalid model, invalid request)
  are never retried — retrying would produce the same failure.
  """
  @spec retryable?(category()) :: boolean()
  def retryable?(:rate_limit), do: true
  def retryable?(:timeout), do: true
  def retryable?(:connection), do: true
  def retryable?(:server), do: true
  def retryable?(_), do: false

  @doc """
  Return the list of retryable error categories.
  """
  @spec retryable_categories() :: [category()]
  def retryable_categories, do: [:rate_limit, :timeout, :connection, :server]

  @doc """
  Return the list of all error categories.
  """
  @spec categories() :: [category()]
  def categories do
    [
      :auth,
      :rate_limit,
      :invalid_model,
      :invalid_request,
      :timeout,
      :connection,
      :server,
      :quota,
      :context_length,
      :unknown
    ]
  end

  # -- Classification logic ----------------------------------------------------

  defp do_classify({:provider_http_error, details}) when is_map(details) do
    status = Map.get(details, :status) || Map.get(details, "status")
    body = Map.get(details, :body_summary) || Map.get(details, "body_summary")

    if is_integer(status) do
      do_classify({:http_error, status, body})
    else
      do_classify({:connection_error, inspect(details, limit: 5, printable_limit: 200)})
    end
  end

  defp do_classify({:provider_network_error, details}) when is_map(details) do
    reason = Map.get(details, :reason) || Map.get(details, "reason") || details
    classify_transport_reason(reason)
  end

  defp do_classify({:sse_transport_error, reason}), do: classify_transport_reason(reason)
  defp do_classify({:transport_error, reason}), do: classify_transport_reason(reason)

  defp do_classify({:http_error, status, _body}) when status in [401, 403] do
    hint =
      if status == 401 do
        "Check your API key with: /auth status"
      else
        "Your API key doesn't have permission for this resource. Check your account permissions."
      end

    {:auth, "Authentication failed (HTTP #{status})", "The provider rejected your credentials.",
     hint, false, status}
  end

  defp do_classify({:http_error, 429, _body}) do
    {:rate_limit, "Rate limited (HTTP 429)", "The provider is rate-limiting your requests.",
     "Wait a moment and retry. Consider reducing request frequency or increasing your rate limit.",
     true, 429}
  end

  defp do_classify({:http_error, 404, _body}) do
    {:invalid_model, "Model not found (HTTP 404)",
     "The requested model doesn't exist or you don't have access.",
     "Check your model name with: /provider models. Verify the model ID in your MUSE_MODEL setting.",
     false, 404}
  end

  defp do_classify({:http_error, 400, _body}) do
    {:invalid_request, "Invalid request (HTTP 400)", "The provider rejected the request payload.",
     "This may be a Muse bug or a model capability mismatch. Try a different model with /provider models.",
     false, 400}
  end

  defp do_classify({:http_error, 402, _body}) do
    {:quota, "Payment required (HTTP 402)", "Your account has insufficient quota or billing.",
     "Check your provider account billing status and add payment if needed.", false, 402}
  end

  defp do_classify({:http_error, status, _body}) when status >= 500 do
    {:server, "Server error (HTTP #{status})", "The provider encountered an internal error.",
     "This is a transient provider-side issue. Retry in a few seconds.", true, status}
  end

  defp do_classify({:http_error, status, _body}) do
    {:unknown, "HTTP error (#{status})", "An unexpected HTTP error occurred.",
     "Check the provider status page or try again later.", false, status}
  end

  defp do_classify(:timeout) do
    {:timeout, "Request timed out", "The provider didn't respond within the timeout period.",
     "Try increasing MUSE_LLM_TIMEOUT_MS or check your network connection.", true, nil}
  end

  defp do_classify({:timeout, _ms}) do
    {:timeout, "Request timed out", "The provider didn't respond within the timeout period.",
     "Try increasing MUSE_LLM_TIMEOUT_MS or check your network connection.", true, nil}
  end

  defp do_classify({:connection_error, _reason}) do
    {:connection, "Connection error", "Could not connect to the provider endpoint.",
     "Check your network connection and base URL. If using Ollama, verify it's running.", true,
     nil}
  end

  defp do_classify({:econnrefused, _}) do
    {:connection, "Connection refused", "The provider endpoint refused the connection.",
     "If using Ollama, make sure it's running: ollama serve. For remote providers, check the base URL.",
     true, nil}
  end

  defp do_classify({:context_length_exceeded, _details}) do
    {:context_length, "Context length exceeded",
     "The request exceeds the model's context window.",
     "Reduce the conversation length or use a model with a larger context window.", false, nil}
  end

  defp do_classify({:rate_limit, _details}) do
    {:rate_limit, "Rate limited", "The provider is rate-limiting your requests.",
     "Wait a moment and retry. Consider reducing request frequency.", true, nil}
  end

  defp do_classify({:auth_error, reason}) when is_binary(reason) do
    {:auth, "Authentication error",
     "The provider rejected authentication: #{redact_string(reason)}",
     "Check your API key with: /auth status", false, nil}
  end

  defp do_classify({:invalid_model, reason}) when is_binary(reason) do
    {:invalid_model, "Invalid model", redact_string(reason),
     "Check available models with: /provider models", false, nil}
  end

  defp do_classify({:server_error, status, reason}) when is_integer(status) do
    {:server, "Server error (HTTP #{status})", redact_string(to_string(reason)),
     "This is a transient provider-side issue. Retry in a few seconds.", true, status}
  end

  # Catch-all for unclassifiable errors
  defp do_classify(reason) when is_binary(reason) do
    # Check for common patterns in string errors
    cond do
      String.contains?(String.downcase(reason), "unauthorized") ->
        do_classify({:http_error, 401, reason})

      String.contains?(String.downcase(reason), "rate limit") ->
        do_classify({:http_error, 429, reason})

      String.contains?(String.downcase(reason), "not found") ->
        do_classify({:http_error, 404, reason})

      String.contains?(String.downcase(reason), "timeout") ->
        do_classify(:timeout)

      String.contains?(String.downcase(reason), "connection") ->
        do_classify({:connection_error, reason})

      String.contains?(String.downcase(reason), "context") and
          String.contains?(String.downcase(reason), "length") ->
        do_classify({:context_length_exceeded, reason})

      true ->
        {:unknown, "Provider error", "An unexpected error occurred: #{redact_string(reason)}",
         "Check /auth status and /provider status for configuration issues.", false, nil}
    end
  end

  defp do_classify(reason) when is_atom(reason) do
    case reason do
      :timeout ->
        do_classify(:timeout)

      :econnrefused ->
        do_classify({:econnrefused, nil})

      :closed ->
        do_classify({:connection_error, "connection closed"})

      _ ->
        {:unknown, "Provider error", "Error: #{inspect(reason)}",
         "Check /auth status and /provider status for configuration issues.", false, nil}
    end
  end

  defp do_classify(_reason) do
    {:unknown, "Provider error", "An unexpected error occurred.",
     "Check /auth status and /provider status for configuration issues.", false, nil}
  end

  defp classify_transport_reason(reason) do
    case do_classify(reason) do
      {:unknown, _title, _message, _hint, _retryable, _status} ->
        do_classify({:connection_error, reason})

      classified ->
        classified
    end
  end

  # -- Redaction ---------------------------------------------------------------

  defp redact_raw(error) do
    error
    |> redact_term()
    |> inspect(limit: 10, printable_limit: 200)
  end

  defp redact_string(binary) when is_binary(binary) do
    Redactor.redact_text(binary)
  end

  defp redact_string(other), do: redact_term(other) |> inspect(limit: 5, printable_limit: 200)

  defp redact_term(term), do: Redactor.redact_term(term)
end
