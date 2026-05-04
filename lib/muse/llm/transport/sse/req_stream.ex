defmodule Muse.LLM.Transport.SSE.ReqStream do
  @moduledoc """
  SSE streaming transport adapter using Req's `into: fun` callback.

  Performs an HTTP POST with `Req.request/2` using the `:into` callback API
  and forwards each response body data chunk to a caller-provided callback.

  ## Req streaming callback shape (`:into` option, Req 0.5)

  When `into` is set to a 2-arity function, Req invokes it for every body
  data chunk:

      into: fn {:data, data}, {req, resp} ->
        {:cont, {req, resp}}
      end

  The `data` argument is a binary of the raw HTTP response body chunk. The
  second argument is a `{Req.Request.t(), Req.Response.t()}` accumulator.
  Return `{:cont, acc}` to continue streaming or `{:halt, acc}` to cancel.

  Req internally handles `{:status, status}`, `{:headers, fields}`, and
  `{:trailers, fields}` events — they are **not** forwarded to the user
  callback. The `resp.status` and `resp.headers` reflect the final HTTP
  response status and headers.

  ## Testability

  Callers may inject a `:post_stream_fn` option to avoid real HTTP calls:

      opts = [
        post_stream_fn: fn _url, _opts, chunk_callback ->
          chunk_callback.("data: hello\\n\\n")
          {:ok, %{status: 200, headers: %{"content-type" => ["text/event-stream"]}}}
        end
      ]

      ReqStream.request(
        [url: "...", body: %{...}, headers: [...]] ++ opts,
        fn chunk ->
          IO.puts(chunk)
        end
      )

  ## Error handling

  All errors are returned (never raised) as `{:error, {:transport_error,
  safe_summary}}`. The summary is a sanitized string representation that
  does **not** include request headers, body, or tokens.
  """

  @type chunk_callback :: (String.t() -> :ok)

  @type post_stream_fn ::
          (String.t(), keyword(), chunk_callback() -> {:ok, map()} | {:error, term()})

  @type result :: {:ok, %{status: pos_integer(), headers: map()}} | {:error, term()}

  @type option ::
          {:url, String.t()}
          | {:body, map()}
          | {:headers, list()}
          | {:receive_timeout, pos_integer()}
          | {:timeout_ms, pos_integer()}
          | {:max_retries, non_neg_integer()}
          | {:post_stream_fn, post_stream_fn()}

  @doc """
  Execute an SSE streaming POST request.

  ## Required options

    * `:url` — the full request URL (string).

  ## Optional options

    * `:body` — JSON-ready payload map (default: `%{}`).
    * `:headers` — list of `{name, value}` header tuples (default: `[]`).
    * `:receive_timeout` — socket receive timeout in milliseconds.
    * `:timeout_ms` — connect timeout in milliseconds (sets `connect_options: [timeout: ms]`).
    * `:max_retries` — maximum number of retry attempts (default: Req built-in `:safe_transient`).
    * `:post_stream_fn` — injectable function for testing (see moduledoc).

  Returns `{:ok, %{status: status, headers: headers}}` on success or
  `{:error, {:transport_error, reason_summary}}` on failure.
  """
  @spec request(keyword(), chunk_callback()) :: result()
  def request(options, chunk_callback) when is_list(options) and is_function(chunk_callback, 1) do
    url = Keyword.fetch!(options, :url)
    body = Keyword.get(options, :body, %{})
    headers = Keyword.get(options, :headers, [])
    post_stream_fn = Keyword.get(options, :post_stream_fn, &default_post_stream/3)

    req_options = build_req_options(body, headers, options)

    case post_stream_fn.(url, req_options, chunk_callback) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:transport_error, safe_summary(reason)}}
    end
  end

  @doc false
  def default_post_stream(url, req_options, chunk_callback)
      when is_binary(url) and is_list(req_options) and is_function(chunk_callback, 1) do
    streaming_options =
      Keyword.put(req_options, :into, fn
        {:data, data}, {req, resp} when is_binary(data) ->
          chunk_callback.(data)
          {:cont, {req, resp}}
      end)

    case Req.request(url, streaming_options) do
      {:ok, %Req.Response{status: status, headers: headers}} when is_integer(status) ->
        {:ok, %{status: status, headers: headers}}

      {:ok, other} ->
        {:error, {:transport_error, safe_summary({:unexpected_response, other})}}

      {:error, exception} ->
        {:error, {:transport_error, safe_summary(exception)}}
    end
  rescue
    e ->
      {:error, {:transport_error, safe_summary(e)}}
  catch
    kind, reason ->
      {:error, {:transport_error, safe_summary({kind, reason})}}
  end

  # ---------------------------------------------------------------------------
  # Option builders
  # ---------------------------------------------------------------------------

  defp build_req_options(body, headers, options) do
    opts = [json: body, headers: headers]

    opts =
      case Keyword.fetch(options, :receive_timeout) do
        {:ok, n} when is_integer(n) and n > 0 -> Keyword.put(opts, :receive_timeout, n)
        _ -> opts
      end

    opts =
      case Keyword.fetch(options, :timeout_ms) do
        {:ok, n} when is_integer(n) and n > 0 ->
          Keyword.put(opts, :connect_options, timeout: n)

        _ ->
          opts
      end

    opts =
      case Keyword.fetch(options, :max_retries) do
        {:ok, n} when is_integer(n) and n >= 0 -> Keyword.put(opts, :max_retries, n)
        _ -> opts
      end

    opts
  end

  # ---------------------------------------------------------------------------
  # Safe error summary (no token leakage)
  # ---------------------------------------------------------------------------

  defp safe_summary(term) when is_binary(term) do
    term
    |> String.slice(0, 500)
    |> Muse.EventPayloadRedactor.redact_string()
  end

  defp safe_summary(term) do
    term
    |> inspect(limit: :infinity, printable_limit: 500)
    |> String.slice(0, 500)
    |> Muse.EventPayloadRedactor.redact_string()
  end
end
