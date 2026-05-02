defmodule Muse.MixProject do
  use Mix.Project

  def project do
    [
      app: :muse,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      mod: {Muse.Application, []},
      extra_applications: [:logger]
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
      {:esbuild, "~> 0.9", runtime: Mix.env() == :dev}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp escript do
    [main_module: Muse.CLI.Main, name: "muse"]
  end
end
