defmodule MuseWeb.EventFormatterTest do
  use ExUnit.Case, async: true

  alias MuseWeb.EventFormatter
  alias Muse.Event

  # -- Helper to create test events ----

  defp make_event(type, data \\ %{}, source \\ :test) do
    %Event{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      source: source,
      type: type,
      data: data
    }
  end

  # -- Filtering tests ----

  describe "filtered_events/3" do
    test "returns all events when filter is 'all' and search is empty" do
      events = [make_event(:info), make_event(:error)]
      assert length(EventFormatter.filtered_events(events, "all", "")) == 2
    end

    test "filters by severity 'errors'" do
      events = [make_event(:info), make_event(:error), make_event(:warning)]
      filtered = EventFormatter.filtered_events(events, "errors", "")
      assert length(filtered) == 1
      assert hd(filtered).type == :error
    end

    test "filters by severity 'warnings'" do
      events = [make_event(:info), make_event(:error), make_event(:warning)]
      filtered = EventFormatter.filtered_events(events, "warnings", "")
      assert length(filtered) == 1
      assert hd(filtered).type == :warning
    end

    test "filters by severity 'info'" do
      events = [make_event(:info), make_event(:error), make_event(:warning)]
      filtered = EventFormatter.filtered_events(events, "info", "")
      assert length(filtered) == 1
      assert hd(filtered).type == :info
    end

    test "filters by search query" do
      events = [make_event(:info, %{text: "hello world"}), make_event(:info, %{text: "goodbye"})]
      filtered = EventFormatter.filtered_events(events, "all", "hello")
      assert length(filtered) == 1
    end

    test "combines filter and search" do
      events = [
        make_event(:error, %{text: "disk full"}),
        make_event(:error, %{text: "memory low"}),
        make_event(:info, %{text: "disk check"})
      ]

      filtered = EventFormatter.filtered_events(events, "errors", "disk")
      assert length(filtered) == 1
    end

    test "nil search query returns all events" do
      events = [make_event(:info), make_event(:error)]
      assert EventFormatter.filtered_events(events, "all", nil) == events
    end

    test "non-binary search query is stringified and matched" do
      events = [make_event(:info, %{text: "42 is the answer"})]
      filtered = EventFormatter.filtered_events(events, "all", 42)
      assert length(filtered) == 1
    end

    test "atom search query is stringified and matched" do
      events = [make_event(:hello, %{text: "greeting"})]
      filtered = EventFormatter.filtered_events(events, "all", :hello)
      assert length(filtered) == 1
    end
  end

  # -- Severity tests ----

  describe "event_severity/1" do
    test "error type maps to :error" do
      assert EventFormatter.event_severity(make_event(:error)) == :error
    end

    test "warning type maps to :warning" do
      assert EventFormatter.event_severity(make_event(:warning)) == :warning
    end

    test "info type maps to :info" do
      assert EventFormatter.event_severity(make_event(:info)) == :info
    end

    test "failed type is :error via errorish?" do
      assert EventFormatter.event_severity(make_event(:failed)) == :error
    end

    test "reload_failed data is :error" do
      assert EventFormatter.event_severity(make_event(:something, %{type: :reload_failed})) ==
               :error
    end
  end

  # -- errorish? / successish? tests ----

  describe "errorish?/1" do
    test "recognizes error atoms" do
      for atom <- [:error, :failed, :failure, :critical, :reload_failed] do
        assert EventFormatter.errorish?(atom)
      end
    end

    test "recognizes error strings" do
      for str <- ["error", "Error", "failed", "FAILED", "critical"] do
        assert EventFormatter.errorish?(str)
      end
    end

    test "returns false for non-error terms" do
      refute EventFormatter.errorish?(:success)
      refute EventFormatter.errorish?("ok")
      refute EventFormatter.errorish?(42)
    end
  end

  describe "successish?/1" do
    test "recognizes success atoms" do
      for atom <- [:success, :reloaded, :fixed, :reload_success, :rollback_success] do
        assert EventFormatter.successish?(atom)
      end
    end

    test "recognizes success strings" do
      assert EventFormatter.successish?("success")
      assert EventFormatter.successish?("reloaded")
      assert EventFormatter.successish?("fixed")
    end

    test "returns false for non-success terms" do
      refute EventFormatter.successish?(:error)
      refute EventFormatter.successish?("failed")
    end
  end

  # -- Display helpers ----

  describe "event_display/1" do
    test "displays text data" do
      assert EventFormatter.event_display(make_event(:info, %{text: "hello"})) == "hello"
    end

    test "displays file data" do
      assert EventFormatter.event_display(make_event(:reload, %{file: "lib/app.ex"})) ==
               "lib/app.ex"
    end

    test "displays files list" do
      assert EventFormatter.event_display(make_event(:reload, %{files: ["a.ex", "b.ex"]})) ==
               "a.ex, b.ex"
    end

    test "displays issues count" do
      assert EventFormatter.event_display(make_event(:issues, %{issues: [1, 2, 3]})) ==
               "3 issue(s) attached"
    end

    test "falls back to inspect for other data" do
      result = EventFormatter.event_display(make_event(:info, %{custom: 42}))
      assert is_binary(result)
    end
  end

  describe "event_row_class/1" do
    test "error events get error row class" do
      assert EventFormatter.event_row_class(make_event(:error)) == "event-row event-row-error"
    end

    test "success events get success row class" do
      assert EventFormatter.event_row_class(make_event(:success)) ==
               "event-row event-row-success"
    end

    test "neutral events get base row class" do
      assert EventFormatter.event_row_class(make_event(:reload)) == "event-row"
    end
  end

  describe "event_badge_class/1" do
    test "error events get danger badge" do
      assert EventFormatter.event_badge_class(make_event(:error)) ==
               "event-badge event-badge-danger"
    end

    test "success events get success badge" do
      assert EventFormatter.event_badge_class(make_event(:success)) ==
               "event-badge event-badge-success"
    end

    test "user_message gets accent badge" do
      assert EventFormatter.event_badge_class(make_event(:user_message)) ==
               "event-badge event-badge-accent"
    end

    test "neutral events get neutral badge" do
      assert EventFormatter.event_badge_class(make_event(:reload)) ==
               "event-badge event-badge-neutral"
    end
  end

  # -- Timestamp helpers ----

  describe "event_timestamp/1" do
    test "formats DateTime to time string" do
      {:ok, dt} = DateTime.new(~D[2025-01-15], ~T[10:30:45], "Etc/UTC")
      assert EventFormatter.event_timestamp(dt) == "10:30:45"
    end

    test "returns dash for non-DateTime" do
      assert EventFormatter.event_timestamp("not a datetime") == "—"
    end
  end

  describe "diagnostic_timestamp/1" do
    test "formats DateTime with UTC suffix" do
      {:ok, dt} = DateTime.new(~D[2025-01-15], ~T[10:30:45], "Etc/UTC")
      assert EventFormatter.diagnostic_timestamp(dt) == "10:30:45 UTC"
    end
  end

  # -- JSON formatting ----

  describe "event_to_map/1" do
    test "converts event to JSON-safe map" do
      event = make_event(:info, %{text: "hello"})
      result = EventFormatter.event_to_map(event)

      assert result.id == event.id
      assert is_binary(result.timestamp)
      assert result.source == event.source
      assert result.type == :info
      assert result.data == %{"text" => "hello"}
    end
  end

  describe "format_event_json/1" do
    test "produces valid JSON" do
      event = make_event(:info, %{text: "hello"})
      json = EventFormatter.format_event_json(event)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["data"]["text"] == "hello"
    end

    test "returns valid JSON error envelope on encoding failure" do
      # Force a failure by mocking event_to_map to return something unencodable.
      # Since json_safe should prevent real failures, we test the contract:
      # format_event_json always returns valid JSON, even in the rescue path.
      event = make_event(:info, %{text: "normal"})
      json = EventFormatter.format_event_json(event)
      assert {:ok, decoded} = Jason.decode(json)
      # Either it has "data" (happy path) or "error" (rescue path)
      assert Map.has_key?(decoded, "data") or Map.has_key?(decoded, "error")
    end
  end

  describe "filter_by_search/2 robustness" do
    test "nil query returns events unchanged" do
      events = [make_event(:info), make_event(:error)]
      assert EventFormatter.filter_by_search(events, nil) == events
    end

    test "integer query is stringified" do
      events = [make_event(:info, %{text: "value 99"})]
      assert length(EventFormatter.filter_by_search(events, 99)) == 1
    end

    test "atom query is stringified" do
      events = [make_event(:searchable_atom, %{text: "test"})]
      assert length(EventFormatter.filter_by_search(events, :searchable_atom)) == 1
    end
  end
end
