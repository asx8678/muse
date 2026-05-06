defmodule Muse.CommandDispatcherHandoffSecurityTest do
  @moduledoc """
  Regression tests for muse-pw9: /handoff target parsing must never create
  atoms from user-controlled input.  Any unknown target string must be rejected
  without calling String.to_atom/1, preventing BEAM atom-table exhaustion.

  Key invariant: after dispatching /handoff with an unknown target, that
  target string must NOT exist as an atom in the BEAM atom table.
  """

  use ExUnit.Case, async: false

  alias Muse.CommandDispatcher
  alias Muse.MuseRegistry

  # -- Helper: check if a string is an existing atom without creating one --
  defp atom_exists?(str) when is_binary(str) do
    String.to_existing_atom(str)
    true
  rescue
    ArgumentError -> false
  end

  # -- Helper: generate a string that is guaranteed not to be an existing atom --
  defp unique_unknown_target do
    int = System.unique_integer([:positive])
    "pw9_unknown_target_#{int}"
  end

  describe "parse_handoff_args — atom safety" do
    test "valid muse id strings are resolved to existing atoms" do
      for id <- MuseRegistry.ids() do
        id_str = Atom.to_string(id)
        # The atom already exists (compile-time), so this should be true
        assert atom_exists?(id_str)
        # And dispatch should accept it (up to session lookup)
        # We only test that parsing succeeds — not the full handoff flow
      end
    end

    test "unknown target string does not become an atom after dispatch" do
      target = unique_unknown_target()

      # Verify the target is NOT already an atom
      refute atom_exists?(target),
             "Precondition failed: #{target} is already an atom"

      # Dispatch with the unknown target — should fail gracefully
      result = CommandDispatcher.dispatch(:handoff, target, %{})

      # Must return an error
      assert match?({:error, _, _}, result)

      # After dispatch, the target string must STILL not be an atom
      refute atom_exists?(target),
             "SECURITY: #{target} became an atom after dispatching /handoff — atom leak!"
    end

    test "repeated unknown targets do not create atoms" do
      # Simulate an attacker sending many unique unknown targets
      targets = for _ <- 1..20, do: unique_unknown_target()

      for target <- targets do
        refute atom_exists?(target),
               "Precondition failed: #{target} is already an atom"

        CommandDispatcher.dispatch(:handoff, target, %{})

        refute atom_exists?(target),
               "SECURITY: #{target} became an atom after /handoff dispatch"
      end
    end

    test "long unknown target does not become an atom" do
      # Long strings that could cause issues with atom table
      target = "pw9_" <> String.duplicate("x", 200)

      refute atom_exists?(target)

      result = CommandDispatcher.dispatch(:handoff, target, %{})
      assert match?({:error, _, _}, result)

      refute atom_exists?(target),
             "SECURITY: long target string became an atom"
    end

    test "special character target does not become an atom" do
      # Strings with special chars that String.to_atom would convert
      target = "pw9_target with spaces and@symbols!"

      # This string can't be a valid atom name, but String.to_atom would
      # create Elixir atoms like :"pw9_target with spaces and@symbols!"
      refute atom_exists?(target)

      result = CommandDispatcher.dispatch(:handoff, target, %{})
      assert match?({:error, _, _}, result)

      refute atom_exists?(target),
             "SECURITY: special-char target string became an atom"
    end
  end

  describe "dispatch(:handoff, ...) — error messages" do
    test "nil args returns usage error" do
      {:error, msg, []} = CommandDispatcher.dispatch(:handoff, nil, %{})
      assert msg =~ "usage"
    end

    test "empty string args returns usage error" do
      {:error, msg, []} = CommandDispatcher.dispatch(:handoff, "", %{})
      assert msg =~ "usage"
    end

    test "whitespace-only args returns usage error" do
      {:error, msg, []} = CommandDispatcher.dispatch(:handoff, "   ", %{})
      assert msg =~ "usage"
    end

    test "unknown target returns not-found error with available muses" do
      target = unique_unknown_target()
      {:error, msg, []} = CommandDispatcher.dispatch(:handoff, target, %{})
      assert msg =~ "unknown Muse target"
      # Should list available muses
      for id <- MuseRegistry.ids() do
        assert msg =~ Atom.to_string(id),
               "Error message should list available muse: #{id}"
      end
    end
  end

  describe "dispatch(:handoff, ...) — valid targets (unit-level)" do
    test "valid target string is accepted by parse step" do
      # We test that valid targets don't return :not_found / :usage errors.
      # The full handoff flow requires a running session, so we only verify
      # the dispatch doesn't reject the target at the parsing stage.
      #
      # For :coding, we expect it to pass parse_handoff_args and hit
      # the SessionRouter lookup (which may fail — but not with :usage/:not_found).
      coding = "coding"

      # Verify coding is a known atom
      assert atom_exists?(coding)

      result = CommandDispatcher.dispatch(:handoff, coding, %{})
      # It should NOT return the "unknown Muse target" or "usage" errors
      case result do
        {:error, msg, _} ->
          refute msg =~ "unknown Muse target",
                 "Valid target 'coding' should not produce 'unknown Muse target' error"

          refute msg =~ "usage:",
                 "Valid target 'coding' should not produce 'usage' error"

        {:ok, _, _} ->
          :ok
      end
    end
  end
end
