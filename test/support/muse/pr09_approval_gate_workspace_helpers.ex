defmodule Muse.PR09ApprovalGateWorkspaceHelpers do
  @moduledoc false

  def session_id(prefix) do
    "pr09-#{prefix}-#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  def tmp_dir! do
    suffix =
      "#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path = Path.join(System.tmp_dir!(), "muse-pr09-approval-gate-#{suffix}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  def seed_workspace(root) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule MyApp.MixProject do
      use Mix.Project

      def project do
        [
          app: :my_app,
          version: "0.1.0",
          elixir: "~> 1.17"
        ]
      end
    end
    """)

    File.write!(Path.join(root, "lib/command_dispatcher.ex"), """
    defmodule MyApp.CommandDispatcher do
      def dispatch(:help, _args, _context) do
        {:ok, "Help text", []}
      end
    end
    """)

    File.write!(Path.join(root, "test/my_app_test.exs"), """
    defmodule MyAppTest do
      use ExUnit.Case

      test "placeholder" do
        assert true
      end
    end
    """)

    File.write!(Path.join(root, ".gitignore"), "# test workspace\n")
    System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)

    System.cmd("git", ["config", "user.email", "muse-test@example.com"],
      cd: root,
      stderr_to_stdout: true
    )

    System.cmd("git", ["config", "user.name", "Muse Test"], cd: root, stderr_to_stdout: true)
    System.cmd("git", ["add", "."], cd: root, stderr_to_stdout: true)

    System.cmd("git", ["commit", "-m", "initial workspace scaffold"],
      cd: root,
      stderr_to_stdout: true
    )

    :ok
  end

  def workspace_snapshot(root) do
    paths =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(fn path -> path |> Path.split() |> Enum.any?(&(&1 == ".git")) end)
      |> Enum.sort()

    hashes =
      Enum.map(paths, fn path ->
        {:ok, content} = File.read(path)
        :erlang.md5(content)
      end)

    {paths, hashes}
  end
end
