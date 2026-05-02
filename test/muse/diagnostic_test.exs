defmodule Muse.DiagnosticTest do
  use ExUnit.Case, async: true

  alias Muse.Diagnostic

  describe "new/3" do
    test "creates a diagnostic with required fields" do
      diagnostic = Diagnostic.new(:warning, "backend warning", %{source: :test})

      assert diagnostic.id > 0
      assert %DateTime{} = diagnostic.timestamp
      assert diagnostic.level == :warning
      assert diagnostic.message == "backend warning"
      assert diagnostic.metadata == %{source: :test}
    end

    test "normalizes :warn to :warning" do
      diagnostic = Diagnostic.new(:warn, "deprecated spelling")

      assert diagnostic.level == :warning
    end

    test "raises for unsupported levels" do
      assert_raise ArgumentError, ~r/unsupported diagnostic level/, fn ->
        Diagnostic.new(:info, "not captured")
      end
    end

    test "converts non-string messages safely" do
      diagnostic = Diagnostic.new(:error, %{error: :boom})

      assert diagnostic.message =~ "%{error: :boom}"
    end

    test "truncates long messages" do
      long = String.duplicate("x", 2_100)
      diagnostic = Diagnostic.new(:critical, long)

      assert String.length(diagnostic.message) == 2_000
      assert diagnostic.message == String.duplicate("x", 2_000)
    end

    test "keeps map metadata as a map" do
      diagnostic = Diagnostic.new(:warning, "metadata", %{file: "lib/muse.ex", line: 12})

      assert diagnostic.metadata == %{file: "lib/muse.ex", line: 12}
    end

    test "wraps non-map metadata in an inspected map" do
      diagnostic = Diagnostic.new(:error, "metadata", {:file, "lib/muse.ex"})

      assert diagnostic.metadata == %{metadata: ~s({:file, "lib/muse.ex"})}
    end

    test "strips ANSI escape sequences from messages" do
      # Red text: \e[31mError\e[0m
      ansi_message = "\e[31mError: something failed\e[0m"
      diagnostic = Diagnostic.new(:error, ansi_message)

      assert diagnostic.message == "Error: something failed"
    end

    test "strips complex ANSI sequences from messages" do
      # Bold red: \e[1;31mAlert\e[0m
      ansi_message = "\e[1;31mAlert\e[0m: check this"
      diagnostic = Diagnostic.new(:critical, ansi_message)

      assert diagnostic.message == "Alert: check this"
    end

    test "leaves clean messages unchanged" do
      diagnostic = Diagnostic.new(:warning, "clean message")

      assert diagnostic.message == "clean message"
    end
  end
end
