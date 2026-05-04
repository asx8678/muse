defmodule Muse.LLM.Transport.SSE.ReqStreamTest do
  use ExUnit.Case, async: true

  alias Muse.LLM.Transport.SSE.ReqStream

  describe "request/2" do
    test "streams chunks via injected post_stream_fn without network" do
      parent = self()

      chunk1 = "data: first chunk"
      chunk2 = "data: second chunk"

      post_stream_fn = fn url, req_options, chunk_callback ->
        send(parent, {:called, url, req_options})

        chunk_callback.(chunk1)
        chunk_callback.(chunk2)

        {:ok, %{status: 200, headers: %{"content-type" => ["text/event-stream"]}}}
      end

      options = [
        url: "https://api.test.example/v1/chat/completions",
        body: %{"model" => "test", "stream" => true},
        headers: [{"Authorization", "Bearer test-token"}],
        receive_timeout: 30_000,
        timeout_ms: 10_000,
        max_retries: 2,
        post_stream_fn: post_stream_fn
      ]

      result =
        ReqStream.request(options, fn chunk ->
          send(parent, {:chunk, chunk})
          :ok
        end)

      assert {:ok, %{status: 200, headers: %{"content-type" => ["text/event-stream"]}}} = result

      assert_receive {:called, url, req_options}
      assert url == "https://api.test.example/v1/chat/completions"
      assert req_options[:json] == %{"model" => "test", "stream" => true}
      assert {"Authorization", "Bearer test-token"} in req_options[:headers]
      assert req_options[:receive_timeout] == 30_000
      assert req_options[:connect_options] == [timeout: 10_000]
      assert req_options[:max_retries] == 2

      assert_receive {:chunk, ^chunk1}
      assert_receive {:chunk, ^chunk2}
    end

    test "forwards non-200 status from injected post_stream_fn" do
      post_stream_fn = fn _url, _req_options, chunk_callback ->
        chunk_callback.("error body text")
        {:ok, %{status: 429, headers: %{"content-type" => ["application/json"]}}}
      end

      options = [
        url: "https://api.test.example/v1/chat/completions",
        body: %{"model" => "test"},
        headers: [],
        max_retries: 0,
        post_stream_fn: post_stream_fn
      ]

      result =
        ReqStream.request(options, fn chunk ->
          send(self(), {:chunk_data, chunk})
          :ok
        end)

      assert {:ok, %{status: 429}} = result
      assert_receive {:chunk_data, "error body text"}
    end

    test "returns wrapped error when injected post_stream_fn returns error" do
      post_stream_fn = fn _url, _req_options, _chunk_callback ->
        {:error, :connection_refused}
      end

      options = [
        url: "https://api.test.example/v1/chat/completions",
        body: %{},
        headers: [],
        max_retries: 0,
        post_stream_fn: post_stream_fn
      ]

      assert {:error, {:transport_error, _summary}} =
               ReqStream.request(options, fn _ -> :ok end)
    end

    test "raises when :url is missing" do
      assert_raise KeyError, ~r/url/, fn ->
        ReqStream.request([body: %{}, headers: []], fn _ -> :ok end)
      end
    end

    test "safe_summary handles error maps" do
      post_stream_fn = fn _url, _req_options, _chunk_callback ->
        {:error, %{reason: :econnrefused, detail: "connection timed out"}}
      end

      options = [
        url: "https://api.test.example/v1/chat/completions",
        body: %{},
        headers: [],
        post_stream_fn: post_stream_fn
      ]

      {:error, {:transport_error, summary}} =
        ReqStream.request(options, fn _ -> :ok end)

      assert is_binary(summary)
      assert summary != ""

      # The error map IS in the summary because transport safe_summary
      # does length-limited inspect; full redaction is at the provider layer.
      assert summary =~ "econnrefused", "error detail should appear in summary"
    end
  end

  describe "default_post_stream/3" do
    test "rejects invalid URL gracefully" do
      result =
        ReqStream.default_post_stream(
          "://invalid",
          [json: %{}, headers: [], retry: false],
          fn _ -> :ok end
        )

      assert {:error, {:transport_error, _summary}} = result
    end

    test "returns error for unreachable host without raising" do
      result =
        ReqStream.default_post_stream(
          "http://127.0.0.1:1/stream",
          [json: %{}, headers: [], retry: false, receive_timeout: 100],
          fn _ -> :ok end
        )

      assert {:error, {:transport_error, _summary}} = result
    end
  end
end
