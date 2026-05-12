defmodule Muse.Tools.GetSourceLocationTest do
  use ExUnit.Case, async: false

  alias Muse.Tools.GetSourceLocation

  # -- Helpers ------------------------------------------------------------------

  defp workspace_root do
    File.cwd!()
  end

  # -- Tests --------------------------------------------------------------------

  describe "execute/2 — module-only lookup" do
    test "returns path:line for a known project module" do
      result =
        GetSourceLocation.execute(%{"reference" => "Muse.Tool.Result"}, %{
          workspace: workspace_root()
        })

      assert result.success, "Expected success, got error: #{inspect(result.error)}"
      assert is_binary(result.output.path)
      assert result.output.path =~ "result.ex"
      assert is_integer(result.output.line)
      assert result.output.source =~ "Muse.Tool.Result"
    end

    test "returns path for a single-segment project module" do
      result =
        GetSourceLocation.execute(%{"reference" => "Muse.Application"}, %{
          workspace: workspace_root()
        })

      assert result.success, "Expected success, got error: #{inspect(result.error)}"
      assert is_binary(result.output.path)
      assert result.output.path =~ "application.ex"
    end
  end

  describe "execute/2 — module.function lookup" do
    test "returns function location for Module.function" do
      result =
        GetSourceLocation.execute(
          %{"reference" => "Muse.Tool.Result.ok"},
          %{workspace: workspace_root()}
        )

      assert result.success, "Expected success, got error: #{inspect(result.error)}"
      assert is_binary(result.output.path)
      assert is_integer(result.output.line)
      assert result.output.line > 0
      assert result.output.source =~ "ok"
    end

    test "returns module location when function not found" do
      # Use a function that likely doesn't exist
      result =
        GetSourceLocation.execute(
          %{"reference" => "Muse.Tool.Result.nonexistent_func"},
          %{workspace: workspace_root()}
        )

      # Should still succeed with module location (function not found → module fallback)
      assert result.success
      assert is_binary(result.output.path)
    end
  end

  describe "execute/2 — module.function/arity lookup" do
    test "returns specific arity location" do
      # Result.ok/2 is a known function
      result =
        GetSourceLocation.execute(
          %{"reference" => "Muse.Tool.Result.ok/2"},
          %{workspace: workspace_root()}
        )

      assert result.success, "Expected success, got error: #{inspect(result.error)}"
      assert is_binary(result.output.path)
      assert is_integer(result.output.line)
      assert result.output.line > 0
      assert result.output.source =~ "ok/2"
    end

    test "returns specific arity for 3-arg variant" do
      result =
        GetSourceLocation.execute(
          %{"reference" => "Muse.Tool.Result.ok/3"},
          %{workspace: workspace_root()}
        )

      assert result.success, "Expected success, got error: #{inspect(result.error)}"
      assert is_integer(result.output.line)
      assert result.output.line > 0
    end
  end

  describe "execute/2 — dep: prefix" do
    test "returns dep root path for known dependency" do
      # phoenix is a known dep in this project
      result =
        GetSourceLocation.execute(
          %{"reference" => "dep:phoenix"},
          %{workspace: workspace_root()}
        )

      assert result.success, "Expected success, got error: #{inspect(result.error)}"
      assert is_binary(result.output.path)
      # Path should be relative to workspace, or absolute deps path
      assert result.output.line == 1
      assert result.output.source == "dep:phoenix"
    end

    test "returns error for unknown dependency" do
      result =
        GetSourceLocation.execute(
          %{"reference" => "dep:nonexistent_package_xyz"},
          %{workspace: workspace_root()}
        )

      refute result.success
      assert result.error =~ "not found"
    end
  end

  describe "execute/2 — error cases" do
    test "returns error for unknown module" do
      result =
        GetSourceLocation.execute(
          %{"reference" => "NonExistentModuleXYZ123"},
          %{workspace: workspace_root()}
        )

      refute result.success
      assert result.error =~ "not found"
    end

    test "returns informative error for core Elixir module" do
      result =
        GetSourceLocation.execute(
          %{"reference" => "Enum"},
          %{workspace: workspace_root()}
        )

      refute result.success
      assert result.error =~ "Core Elixir" or result.error =~ "source not available"
    end

    test "returns informative error for Kernel module" do
      result =
        GetSourceLocation.execute(
          %{"reference" => "Kernel"},
          %{workspace: workspace_root()}
        )

      refute result.success
      assert result.error =~ "Core Elixir" or result.error =~ "source not available"
    end

    test "returns error when reference argument is missing" do
      result = GetSourceLocation.execute(%{}, %{workspace: workspace_root()})

      refute result.success
      assert result.error =~ "reference"
    end

    test "returns error for invalid reference syntax" do
      result =
        GetSourceLocation.execute(
          %{"reference" => "!!!invalid"},
          %{workspace: workspace_root()}
        )

      refute result.success
      assert result.error =~ "Invalid reference" or result.error =~ "Could not parse"
    end
  end

  describe "execute/2 — path relativization" do
    test "paths are relative to workspace root" do
      result =
        GetSourceLocation.execute(%{"reference" => "Muse.Tool.Result"}, %{
          workspace: workspace_root()
        })

      assert result.success
      # Path should not be absolute
      refute String.starts_with?(result.output.path, "/")
    end
  end
end
