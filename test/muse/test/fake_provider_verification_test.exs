defmodule Muse.Test.FakeProviderVerificationTest do
  @moduledoc """
  T0-00 Verification: Muse.LLM.FakeProvider is deterministic and offline.

  These tests confirm the existing `Muse.LLM.FakeProvider` satisfies
  the acceptance criteria for a "fake LLM provider" — it is:
    1. Fully deterministic (same input → same output)
    2. Fully offline (no network calls)
    3. Scriptable via request options
  """
  use ExUnit.Case, async: true

  alias Muse.LLM.{FakeProvider, Message, Request, Response}

  defp default_request(opts \\ []) do
    text = Keyword.get(opts, :user_text, "add a /version command")
    options = Keyword.get(opts, :options, %{})

    %Request{
      provider: :fake,
      model: "fake-planning-model",
      messages: [Message.user(text)],
      options: options
    }
  end

  defp collect_events(request) do
    {:ok, ref} = Agent.start_link(fn -> [] end)

    result =
      FakeProvider.stream(request, fn event ->
        Agent.update(ref, &[event | &1])
        :ok
      end)

    events = Agent.get(ref, &Enum.reverse/1)
    Agent.stop(ref)

    case result do
      {:ok, response} -> {:ok, response, events}
      {:error, reason} -> {:error, reason, events}
    end
  end

  # ---------------------------------------------------------------------------
  # Determinism
  # ---------------------------------------------------------------------------

  describe "FakeProvider — determinism" do
    test "same input produces same default output" do
      request = default_request()

      {:ok, response1, events1} = collect_events(request)
      {:ok, response2, events2} = collect_events(request)

      assert response1.content == response2.content
      assert length(events1) == length(events2)
    end

    test "same scripted input produces same scripted output" do
      script = [
        {:assistant_delta, "Hello"},
        {:assistant_completed, "Hello world"},
        {:response_completed, nil}
      ]

      request = default_request(options: %{fake_events: script})

      {:ok, response1, _events1} = collect_events(request)
      {:ok, response2, _events2} = collect_events(request)

      assert response1.content == response2.content
      assert response1.content == "Hello world"
    end
  end

  # ---------------------------------------------------------------------------
  # Offline — no network dependency
  # ---------------------------------------------------------------------------

  describe "FakeProvider — offline" do
    test "works without any network connectivity (no external calls)" do
      # This test passes trivially since FakeProvider never makes network calls.
      # The real value is: any test using FakeProvider can be run in CI
      # or air-gapped environments.
      request = default_request()
      assert {:ok, _response, _events} = collect_events(request)
    end
  end

  # ---------------------------------------------------------------------------
  # Scripting
  # ---------------------------------------------------------------------------

  describe "FakeProvider — scripting" do
    test "emits scripted events in order" do
      script = [
        {:assistant_delta, "Step 1"},
        {:assistant_delta, " Step 2"},
        {:assistant_completed, "Step 1 Step 2"},
        {:response_completed, nil}
      ]

      request = default_request(options: %{fake_events: script})

      {:ok, _response, events} = collect_events(request)

      event_types = Enum.map(events, & &1.type)

      assert event_types == [
               :assistant_delta,
               :assistant_delta,
               :assistant_completed,
               :response_completed
             ]
    end

    test "scripted tool call emits start and completed events" do
      script = [
        {:tool_call, "read_file", %{"path" => "lib/a.ex"}},
        {:assistant_completed, "Done"},
        {:response_completed, nil}
      ]

      request = default_request(options: %{fake_events: script})

      {:ok, response, events} = collect_events(request)

      tool_start = Enum.find(events, &(&1.type == :tool_call_started))
      tool_done = Enum.find(events, &(&1.type == :tool_call_completed))

      assert tool_start != nil
      assert tool_done != nil
      assert length(response.tool_calls) == 1
    end

    test "scripted error returns {:error, reason}" do
      script = [
        {:error, "test error"}
      ]

      request = default_request(options: %{fake_events: script})

      assert {:error, _reason, events} = collect_events(request)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end

    test "fake_error option returns error immediately" do
      request = default_request(options: %{fake_error: "instant error"})

      assert {:error, _reason, events} = collect_events(request)
      assert Enum.any?(events, &(&1.type == :provider_error))
    end
  end

  # ---------------------------------------------------------------------------
  # complete/2 — offline and deterministic
  # ---------------------------------------------------------------------------

  describe "FakeProvider — complete/2" do
    test "returns deterministic response without streaming" do
      request = default_request()

      assert {:ok, %Response{} = response} = FakeProvider.complete(request)
      assert response.finish_reason == "stop"
      assert is_binary(response.content)
    end

    test "scripted complete/2 produces same result as stream/2" do
      script = [
        {:assistant_delta, "Hello"},
        {:assistant_completed, "Hello world"},
        {:response_completed, nil}
      ]

      request = default_request(options: %{fake_events: script})

      {:ok, stream_response, _} = collect_events(request)
      {:ok, complete_response} = FakeProvider.complete(request)

      assert stream_response.content == complete_response.content
    end
  end
end
