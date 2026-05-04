defmodule Muse.Fixtures.FakeProviderContractTest do
  @moduledoc """
  Contract tests for fake provider fixture files.

  Validates that:
  - All referenced fixture files exist and are parseable
  - JSONL fixtures produce valid FakeProvider events
  - Planning flow fixtures contain valid structured plan JSON
  - Batched fixtures can drive the full Planning Muse tool loop
  """
  use ExUnit.Case, async: true

  alias Muse.LLM.{FakeProvider, Message, Request}
  alias Muse.{PlanParser, PlanSchema}

  @fixtures_dir Path.expand("../../fixtures/fake_provider", __DIR__)

  # -- Helper: load JSONL fixture lines as decoded maps -------------------------

  defp load_jsonl(filename) do
    path = Path.join(@fixtures_dir, filename)
    assert File.exists?(path), "Fixture file not found: #{path}"

    entries =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert length(entries) > 0, "Fixture #{filename} is empty"
    entries
  end

  # -- Helper: load JSON fixture as decoded map/list ----------------------------

  defp load_json(filename) do
    path = Path.join(@fixtures_dir, filename)
    assert File.exists?(path), "Fixture file not found: #{path}"

    path
    |> File.read!()
    |> Jason.decode!()
  end

  # -- Helper: collect events from a FakeProvider stream call -------------------

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

  defp default_request(opts) do
    text = Keyword.get(opts, :user_text, "plan the version command")
    options = Keyword.get(opts, :options, %{})

    %Request{
      provider: :fake,
      model: "fake-planning-model",
      messages: [Message.user(text)],
      options: options
    }
  end

  # ---------------------------------------------------------------------------
  # Fixture file existence and parseability
  # ---------------------------------------------------------------------------

  describe "fixture file existence" do
    test "planning_flow.jsonl exists and is valid JSONL" do
      entries = load_jsonl("planning_flow.jsonl")
      assert is_list(entries)
      assert Enum.all?(entries, &is_map/1)
    end

    test "planning_flow_batches.json exists and is valid JSON" do
      data = load_json("planning_flow_batches.json")
      assert is_map(data)
      assert Map.has_key?(data, "batches")
      assert is_list(data["batches"])
      assert length(data["batches"]) >= 2
    end

    test "tool_calls_then_text.jsonl exists and is valid JSONL" do
      entries = load_jsonl("tool_calls_then_text.jsonl")
      assert is_list(entries)
      assert Enum.all?(entries, &is_map/1)
    end
  end

  # ---------------------------------------------------------------------------
  # planning_flow.jsonl — single-batch Planning Muse turn
  # ---------------------------------------------------------------------------

  describe "planning_flow.jsonl — single-batch fixture" do
    setup do
      entries = load_jsonl("planning_flow.jsonl")
      %{entries: entries}
    end

    test "can be used as fake_events in FakeProvider", %{entries: entries} do
      request = default_request(options: %{fake_events: entries})
      assert {:ok, _response, _events} = collect_events(request)
    end

    test "emits canonical event types in valid order", %{entries: entries} do
      request = default_request(options: %{fake_events: entries})
      {:ok, _response, events} = collect_events(request)

      event_types = Enum.map(events, & &1.type)

      assert :assistant_delta in event_types
      assert :tool_call_completed in event_types
      assert :assistant_completed in event_types
      assert :response_completed in event_types
    end

    test "includes read-only tool calls (list_files, read_file)", %{entries: entries} do
      request = default_request(options: %{fake_events: entries})
      {:ok, response, _events} = collect_events(request)

      tool_names = Enum.map(response.tool_calls, & &1.name)
      assert "list_files" in tool_names
      assert "read_file" in tool_names
    end

    test "assistant_completed text contains valid plan JSON", %{entries: entries} do
      request = default_request(options: %{fake_events: entries})
      {:ok, response, _events} = collect_events(request)

      assert {:ok, %Muse.Plan{} = plan} = PlanParser.parse(response.content)
      assert plan.objective =~ "/version"
      assert length(plan.tasks) >= 2
    end

    test "plan JSON in fixture passes PlanSchema validation", %{entries: entries} do
      completed_entry =
        Enum.find(entries, fn entry ->
          event_type = entry["event"] || entry["type"]
          event_type == "assistant_completed"
        end)

      assert completed_entry != nil, "Expected assistant_completed entry in fixture"
      plan_text = completed_entry["text"]
      assert plan_text != nil

      {:ok, decoded} = Jason.decode(plan_text)
      assert {:ok, _normalized} = PlanSchema.validate(decoded)
    end

    test "no write/shell tools in fixture tool calls", %{entries: entries} do
      tool_call_entries =
        Enum.filter(entries, fn entry ->
          (entry["event"] || entry["type"]) == "tool_call"
        end)

      write_tools =
        ~w(write_file replace_in_file delete_file patch_apply patch_propose shell_command)

      for entry <- tool_call_entries do
        refute entry["name"] in write_tools,
               "Planning flow fixture should not contain write tool: #{entry["name"]}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # planning_flow_batches.json — multi-batch E2E Planning Muse fixture
  # ---------------------------------------------------------------------------

  describe "planning_flow_batches.json — multi-batch fixture" do
    setup do
      data = load_json("planning_flow_batches.json")
      batches = data["batches"]
      %{batches: batches}
    end

    test "each batch is a valid list of FakeProvider script entries", %{batches: batches} do
      for batch <- batches do
        assert is_list(batch)
        assert length(batch) > 0

        for entry <- batch do
          assert is_map(entry)
          assert entry["event"] != nil or entry["type"] != nil
        end
      end
    end

    test "batch 0 and 1 contain tool calls; batch 2 contains plan JSON", %{
      batches: batches
    } do
      [batch0, batch1, batch2 | _] = batches

      batch0_tool_calls =
        Enum.filter(batch0, fn e -> (e["event"] || e["type"]) == "tool_call" end)

      assert length(batch0_tool_calls) >= 1

      batch1_tool_calls =
        Enum.filter(batch1, fn e -> (e["event"] || e["type"]) == "tool_call" end)

      assert length(batch1_tool_calls) >= 1

      batch2_completed =
        Enum.filter(batch2, fn e -> (e["event"] || e["type"]) == "assistant_completed" end)

      assert length(batch2_completed) == 1

      plan_text = hd(batch2_completed)["text"]
      assert {:ok, _plan} = PlanParser.parse(plan_text)
    end

    test "each batch can be used as fake_events in FakeProvider", %{batches: batches} do
      for {batch, idx} <- Enum.with_index(batches) do
        request = default_request(options: %{fake_events: batch})

        assert {:ok, _response, _events} = collect_events(request),
               "Batch #{idx} failed to produce a valid FakeProvider response"
      end
    end

    test "batch 2 produces a valid plan through FakeProvider", %{batches: batches} do
      batch2 = Enum.at(batches, 2)
      request = default_request(options: %{fake_events: batch2})
      {:ok, response, _events} = collect_events(request)

      assert {:ok, plan} = PlanParser.parse(response.content)
      assert plan.objective =~ "/version"
      assert length(plan.tasks) == 3
    end

    test "no write/shell tools in any batch", %{batches: batches} do
      write_tools =
        ~w(write_file replace_in_file delete_file patch_apply patch_propose shell_command)

      for {batch, idx} <- Enum.with_index(batches) do
        tool_calls =
          Enum.filter(batch, fn e -> (e["event"] || e["type"]) == "tool_call" end)

        for entry <- tool_calls do
          refute entry["name"] in write_tools,
                 "Batch #{idx} should not contain write tool: #{entry["name"]}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # tool_calls_then_text.jsonl — backward compatibility
  # ---------------------------------------------------------------------------

  describe "tool_calls_then_text.jsonl — backward compatibility" do
    test "can be loaded and used as fake_events" do
      entries = load_jsonl("tool_calls_then_text.jsonl")
      request = default_request(options: %{fake_events: entries})

      {:ok, response, events} = collect_events(request)

      tool_call_events = Enum.filter(events, &(&1.type == :tool_call_completed))
      assert length(tool_call_events) >= 2

      assert response.usage != nil
      assert response.usage["prompt_tokens"] == 250
    end
  end
end
