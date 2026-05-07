defmodule Muse.Execution.RemoteRunnerTest do
  use ExUnit.Case, async: true

  alias Muse.Execution.RemoteRunner

  describe "behaviour callbacks" do
    test "defines connect/2, disconnect/1, remote_run/3 callbacks" do
      callbacks =
        RemoteRunner.behaviour_info(:callbacks)
        |> Enum.filter(fn {name, _arity} -> name in [:connect, :disconnect, :remote_run] end)
        |> Enum.map(fn {name, arity} -> {name, arity} end)

      assert {:%{}, [], [{:connect, 2}, {:disconnect, 1}, {:remote_run, 3}]} ==
               {:%{}, [], Enum.sort(callbacks)}
    end

    test "all three callbacks are required" do
      # RemoteRunner has no optional_callbacks for its own callbacks
      required =
        RemoteRunner.behaviour_info(:callbacks)
        |> Enum.filter(fn {name, _arity} -> name in [:connect, :disconnect, :remote_run] end)

      assert length(required) == 3
    end
  end

  describe "module documentation" do
    test "has documentation" do
      {:docs_v1, _, _, _, doc_map, _, _} = Code.fetch_docs(RemoteRunner)
      assert doc_map["en"] != nil
      assert doc_map["en"] =~ "Extension behaviour"
    end
  end
end
