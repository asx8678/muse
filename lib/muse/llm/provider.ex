defmodule Muse.LLM.Provider do
  @moduledoc """
  Behavior definition for LLM provider adapters.

  Every provider — fake, OpenAI, OpenRouter, Ollama — implements this
  behavior. The runtime calls `stream/2` (primary) or `complete/2`
  (optional fallback) and receives normalized `Muse.LLM.Event.t()` and
  `Muse.LLM.Response.t()` structs.

  ## Streaming (primary callback)

  `stream/2` accepts a `Muse.LLM.Request.t()` and an emit callback.
  The provider calls `emit.(event)` zero or more times with
  `Muse.LLM.Event.t()` structs, then returns the final
  `Muse.LLM.Response.t()`.

      {:ok, response} = MyProvider.stream(request, fn event ->
        # handle event (e.g., forward to session event log)
        :ok
      end)

  The emit callback always returns `:ok`.  Providers must not depend on
  its return value for flow control.

  ## Non-streaming (optional callback)

  `complete/2` is a convenience wrapper for providers that support a
  single-shot request/response without incremental events.  If a
  provider does not implement `complete/2`, the default implementation
  raises `UndefinedFunctionError`.

  ## Error convention

  Both callbacks return `{:error, term()}` on failure.  The error term
  is **always redacted** by the provider before returning — it must
  never contain API keys, bearer tokens, or other secrets.
  """

  alias Muse.LLM.{Event, Request, Response}

  @doc """
  Stream a request, emitting normalized events via the callback.

  Returns `{:ok, response}` on success or `{:error, redacted_reason}` on failure.
  """
  @callback stream(Request.t(), (Event.t() -> :ok)) ::
              {:ok, Response.t()} | {:error, term()}

  @doc """
  Complete a request without streaming events.

  Returns `{:ok, response}` on success or `{:error, redacted_reason}` on failure.
  Optional — providers that only support streaming may omit this callback.
  """
  @callback complete(Request.t(), keyword()) ::
              {:ok, Response.t()} | {:error, term()}

  @optional_callbacks [complete: 2]
end
