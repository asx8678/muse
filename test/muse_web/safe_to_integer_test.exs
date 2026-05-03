defmodule MuseWeb.SafeToIntegerTest do
  use ExUnit.Case, async: true

  describe "safe_to_integer/1" do
    test "parses valid integer strings" do
      assert MuseWeb.safe_to_integer("42") == {:ok, 42}
      assert MuseWeb.safe_to_integer("0") == {:ok, 0}
      assert MuseWeb.safe_to_integer("-7") == {:ok, -7}
    end

    test "passes through integer values" do
      assert MuseWeb.safe_to_integer(42) == {:ok, 42}
      assert MuseWeb.safe_to_integer(0) == {:ok, 0}
      assert MuseWeb.safe_to_integer(-7) == {:ok, -7}
    end

    test "rejects non-integer strings" do
      assert MuseWeb.safe_to_integer("abc") == :error
      assert MuseWeb.safe_to_integer("") == :error
      assert MuseWeb.safe_to_integer("1x") == :error
      assert MuseWeb.safe_to_integer("3.14") == :error
      assert MuseWeb.safe_to_integer(" 42") == :error
      assert MuseWeb.safe_to_integer("42 ") == :error
    end

    test "rejects non-numeric types" do
      assert MuseWeb.safe_to_integer(nil) == :error
      assert MuseWeb.safe_to_integer(3.14) == :error
      assert MuseWeb.safe_to_integer([1]) == :error
      assert MuseWeb.safe_to_integer(%{}) == :error
    end
  end

  describe "safe_to_integer_or_nil/1" do
    test "returns integer for valid input" do
      assert MuseWeb.safe_to_integer_or_nil("42") == 42
      assert MuseWeb.safe_to_integer_or_nil(7) == 7
    end

    test "returns nil for invalid input" do
      assert MuseWeb.safe_to_integer_or_nil("abc") == nil
      assert MuseWeb.safe_to_integer_or_nil("") == nil
      assert MuseWeb.safe_to_integer_or_nil("1x") == nil
      assert MuseWeb.safe_to_integer_or_nil(nil) == nil
    end
  end
end
