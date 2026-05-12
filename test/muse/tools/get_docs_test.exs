defmodule Muse.Tools.GetDocsTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.GetDocs

  describe "execute/2 — module docs" do
    test "returns valid markdown for a well-documented module" do
      result = GetDocs.execute(%{"reference" => "Enum"}, %{})

      assert result.success
      assert result.output.reference == "Enum"
      assert result.output.markdown =~ "# Enum"
      assert result.output.markdown =~ "## Functions & Callbacks"
    end

    test "includes function signatures in module listing" do
      result = GetDocs.execute(%{"reference" => "Enum"}, %{})

      assert result.success
      assert result.output.markdown =~ "```elixir"
    end

    test "lists known functions in module docs" do
      result = GetDocs.execute(%{"reference" => "Enum"}, %{})

      assert result.success
      assert result.output.markdown =~ "map/2"
    end
  end

  describe "execute/2 — function docs" do
    test "returns signature and description for a specific function/arity" do
      result = GetDocs.execute(%{"reference" => "Enum.map/2"}, %{})

      assert result.success
      assert result.output.reference == "Enum.map/2"
      assert result.output.markdown =~ "# Enum.map/2"
      assert result.output.markdown =~ "```elixir"
      assert result.output.markdown =~ "map"
    end

    test "returns all arities when function is specified without arity" do
      result = GetDocs.execute(%{"reference" => "Enum.map"}, %{})

      assert result.success
      assert result.output.markdown =~ "Enum.map"
    end
  end

  describe "execute/2 — callback docs" do
    test "returns callback documentation with c: prefix" do
      result = GetDocs.execute(%{"reference" => "c:GenServer.handle_call/3"}, %{})

      assert result.success
      assert result.output.markdown =~ "handle_call"
      assert result.output.markdown =~ "callback"
    end
  end

  describe "execute/2 — undocumented/nonexistent module" do
    test "returns error for nonexistent module" do
      result = GetDocs.execute(%{"reference" => "NonExistentModuleXYZ123"}, %{})

      refute result.success
      assert result.error =~ "does not exist"
    end

    test "returns message for undocumented function" do
      result = GetDocs.execute(%{"reference" => "Enum.nonexistent_function_xyz/1"}, %{})

      assert result.success
      assert result.output.markdown =~ "No function"
    end
  end

  describe "execute/2 — invalid reference" do
    test "returns parse error for invalid syntax" do
      result = GetDocs.execute(%{"reference" => "not valid!!"}, %{})

      refute result.success
      assert result.error =~ "invalid reference"
    end

    test "returns error when reference argument is missing" do
      result = GetDocs.execute(%{}, %{})

      refute result.success
      assert result.error =~ "reference is required"
    end

    test "returns error when reference is empty string" do
      result = GetDocs.execute(%{"reference" => ""}, %{})

      refute result.success
      assert result.error =~ "reference is required"
    end
  end

  describe "execute/2 — Erlang module docs" do
    @tag :erlang_docs
    test "returns docs for Erlang module when available" do
      result = GetDocs.execute(%{"reference" => ":gen_server"}, %{})

      # Erlang docs may or may not be available depending on OTP version
      if result.success do
        assert result.output.markdown =~ ":gen_server"
      else
        assert result.error =~ "no documentation"
      end
    end
  end
end
