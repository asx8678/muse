defmodule Muse.MixProject do
  use Mix.Project

  def project do
    [
      app: :muse,
      version: "0.2.1",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test, test: :test]
    ]
  end

  def application do
    [
      mod: {Muse.Application, []},
      extra_applications: [:logger, :ssh, :crypto]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_pubsub, "~> 2.2"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.9", runtime: Mix.env() == :dev},
      {:req, "~> 0.5"},
      {:ex_ratatui, "~> 0.8"},
      {:mint_web_socket, "~> 1.0"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp escript do
    [main_module: Muse.CLI.Main, name: "muse"]
  end

  defp aliases do
    [
      "assets.deploy": ["muse.assets"],
      "assets.build": ["muse.assets"],
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "cmd mix hex.audit",
        "test"
      ]
    ]
  end

  defp releases do
    [
      muse: [
        applications: [muse: :permanent],
        include_executables_for: [:unix],
        overlays: ["rel/overlays"],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
