defmodule Muse.Tools.GetEctoSchemasTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.GetEctoSchemas

  describe "execute/2 — basic listing" do
    test "returns schemas list and count with test injection" do
      test_schemas = [
        %{module: "MyApp.Post", file: "lib/my_app/post.ex", ash_resource?: false},
        %{module: "MyApp.User", file: "lib/my_app/user.ex", ash_resource?: true}
      ]

      result = GetEctoSchemas.execute(%{"muse_test_schemas" => test_schemas}, %{})

      assert result.success
      assert length(result.output.schemas) == 2
      assert result.output.count == 2
    end

    test "returns empty list when no schemas found via test injection" do
      result = GetEctoSchemas.execute(%{"muse_test_schemas" => []}, %{})

      assert result.success
      assert result.output.schemas == []
      assert result.output.count == 0
    end

    test "accepts test schemas from context metadata" do
      test_schemas = [
        %{module: "MyApp.Comment", file: "lib/my_app/comment.ex", ash_resource?: false}
      ]

      result = GetEctoSchemas.execute(%{}, %{muse_test_schemas: test_schemas})

      assert result.success
      assert result.output.count == 1
    end

    test "each schema entry has module, file, and ash_resource? keys" do
      test_schemas = [
        %{module: "MyApp.Post", file: "lib/my_app/post.ex", ash_resource?: false}
      ]

      result = GetEctoSchemas.execute(%{"muse_test_schemas" => test_schemas}, %{})

      assert result.success
      [entry] = result.output.schemas
      assert Map.has_key?(entry, :module)
      assert Map.has_key?(entry, :file)
      assert Map.has_key?(entry, :ash_resource?)
    end

    test "args injection takes precedence over context" do
      args_schemas = [%{module: "FromArgs", file: "a.ex", ash_resource?: false}]
      ctx_schemas = [%{module: "FromContext", file: "b.ex", ash_resource?: false}]

      result =
        GetEctoSchemas.execute(%{"muse_test_schemas" => args_schemas}, %{
          muse_test_schemas: ctx_schemas
        })

      assert result.success
      assert hd(result.output.schemas).module == "FromArgs"
    end
  end

  describe "execute/2 — Ecto not available" do
    @tag :skip
    test "returns error when Ecto is not loaded"
  end

  describe "execute/2 — live discovery" do
    @tag :skip
    test "discovers Ecto schemas from loaded modules (requires Ecto project)"
  end
end
