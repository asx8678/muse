defmodule Muse.Tools.ExecuteSqlTest do
  use ExUnit.Case, async: true

  alias Muse.Tools.ExecuteSql

  describe "execute/2 — mutation guard" do
    test "blocks INSERT queries" do
      result = ExecuteSql.execute(%{"query" => "INSERT INTO users (name) VALUES ('alice')"}, %{})

      refute result.success
      assert result.error =~ "Only SELECT queries are allowed"
    end

    test "blocks UPDATE queries" do
      result = ExecuteSql.execute(%{"query" => "UPDATE users SET name = 'bob'"}, %{})

      refute result.success
      assert result.error =~ "Only SELECT queries are allowed"
    end

    test "blocks DELETE queries" do
      result = ExecuteSql.execute(%{"query" => "DELETE FROM users"}, %{})

      refute result.success
      assert result.error =~ "Only SELECT queries are allowed"
    end

    test "blocks DROP queries" do
      result = ExecuteSql.execute(%{"query" => "DROP TABLE users"}, %{})

      refute result.success
      assert result.error =~ "Only SELECT queries are allowed"
    end

    test "blocks ALTER queries" do
      result = ExecuteSql.execute(%{"query" => "ALTER TABLE users ADD COLUMN age int"}, %{})

      refute result.success
      assert result.error =~ "Only SELECT queries are allowed"
    end

    test "blocks TRUNCATE queries" do
      result = ExecuteSql.execute(%{"query" => "TRUNCATE TABLE users"}, %{})

      refute result.success
      assert result.error =~ "Only SELECT queries are allowed"
    end

    test "blocks mutation with leading whitespace" do
      result = ExecuteSql.execute(%{"query" => "  INSERT INTO users (name) VALUES ('x')"}, %{})

      refute result.success
      assert result.error =~ "Only SELECT queries are allowed"
    end
  end

  describe "execute/2 — missing query param" do
    test "returns error when query is missing" do
      result = ExecuteSql.execute(%{}, %{})

      refute result.success
      assert result.error =~ "query is required"
    end

    test "returns error when query is empty string" do
      result = ExecuteSql.execute(%{"query" => ""}, %{})

      refute result.success
      assert result.error =~ "query must be a non-empty string"
    end

    test "returns error when query is not a string" do
      result = ExecuteSql.execute(%{"query" => 123}, %{})

      refute result.success
      assert result.error =~ "query must be a non-empty string"
    end
  end

  describe "execute/2 — no Ecto repos" do
    @tag :skip
    test "returns error when no Ecto repos are configured"
  end

  describe "execute/2 — successful SELECT (requires Ecto + repo)" do
    @tag :skip
    test "returns columns, rows, truncated, total_rows for a valid SELECT"

    @tag :skip
    test "truncates results exceeding 50 rows"
  end
end
