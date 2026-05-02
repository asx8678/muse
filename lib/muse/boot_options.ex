defmodule Muse.BootOptions do
  @moduledoc """
  Typed struct representing every CLI flag Muse understands.

  `parse!/1` turns a raw argv list into a `%Muse.BootOptions{}` struct,
  resolving the workspace to an absolute path and validating everything
  up-front so the rest of the app can trust the values blindly.
  """

  @enforce_keys []
  defstruct cli?: true,
            web?: true,
            host: "127.0.0.1",
            port: 4000,
            workspace: nil,
            watch?: true,
            help?: false

  @type t :: %__MODULE__{
          cli?: boolean(),
          web?: boolean(),
          host: String.t(),
          port: pos_integer(),
          workspace: String.t() | nil,
          watch?: boolean(),
          help?: boolean()
        }

  # -- OptionParser strict spec ------------------------------------------------
  # Keys use underscores (OptionParser normalizes --web-only → :web_only).
  # `watch: :boolean` auto-supports --no-watch (sets watch: false).

  @strict [
    no_web: :boolean,
    web_only: :boolean,
    no_cli: :boolean,
    port: :integer,
    host: :string,
    workspace: :string,
    watch: :boolean,
    help: :boolean
  ]

  @aliases [
    h: :help,
    p: :port,
    w: :workspace
  ]

  # -- Public API ---------------------------------------------------------------

  @spec parse!([String.t()]) :: t()
  def parse!(argv) when is_list(argv) do
    {parsed, positional, invalid} =
      OptionParser.parse(argv, strict: @strict, aliases: @aliases)

    validate_no_invalid!(invalid)
    validate_no_positional!(positional)
    validate_port!(parsed[:port])

    build(parsed)
  end

  # -- Build --------------------------------------------------------------------

  defp build(parsed) do
    opts = %__MODULE__{}

    opts
    |> apply_mode_flags(parsed)
    |> apply_host(parsed)
    |> apply_port(parsed)
    |> apply_workspace(parsed)
    |> apply_watch(parsed)
    |> apply_help(parsed)
    |> resolve_workspace!()
  end

  # -- Mode flags (cli? / web?) -------------------------------------------------

  defp apply_mode_flags(opts, parsed) do
    cond do
      parsed[:web_only] ->
        %{opts | cli?: false, web?: true}

      parsed[:no_cli] ->
        %{opts | cli?: false, web?: true}

      parsed[:no_web] ->
        %{opts | cli?: true, web?: false}

      true ->
        opts
    end
  end

  # -- Individual field appliers ------------------------------------------------

  defp apply_host(opts, parsed) do
    case Keyword.get(parsed, :host) do
      nil -> opts
      host -> %{opts | host: host}
    end
  end

  defp apply_port(opts, parsed) do
    case Keyword.get(parsed, :port) do
      nil -> opts
      port -> %{opts | port: port}
    end
  end

  defp apply_workspace(opts, parsed) do
    case Keyword.get(parsed, :workspace) do
      nil -> opts
      path -> %{opts | workspace: path}
    end
  end

  defp apply_watch(opts, parsed) do
    cond do
      # --no-watch is auto-negation of watch: :boolean → parsed[:watch] == false
      Keyword.has_key?(parsed, :watch) and parsed[:watch] == false ->
        %{opts | watch?: false}

      # --watch → parsed[:watch] == true
      parsed[:watch] == true ->
        %{opts | watch?: true}

      true ->
        opts
    end
  end

  defp apply_help(opts, parsed) do
    if parsed[:help], do: %{opts | help?: true}, else: opts
  end

  # -- Workspace resolution -----------------------------------------------------

  defp resolve_workspace!(%{workspace: nil} = opts) do
    %{opts | workspace: workspace_fallback()}
  end

  defp resolve_workspace!(%{workspace: path} = opts) do
    %{opts | workspace: Path.expand(path)}
  end

  defp workspace_fallback do
    case System.get_env("MUSE_WORKSPACE") do
      nil -> File.cwd!()
      env -> Path.expand(env)
    end
  end

  # -- Validation ---------------------------------------------------------------

  defp validate_port!(nil), do: :ok

  defp validate_port!(port) when is_integer(port) and port in 1..65535, do: :ok

  defp validate_port!(port) do
    raise ArgumentError,
          "invalid port #{inspect(port)}; must be an integer in 1..65535"
  end

  defp validate_no_positional!([]), do: :ok

  defp validate_no_positional!(args) do
    raise ArgumentError,
          "unexpected positional argument(s): #{Enum.join(args, " ")}"
  end

  defp validate_no_invalid!([]), do: :ok

  defp validate_no_invalid!(invalid) do
    formatted =
      invalid
      |> Enum.map(fn {flag, value} -> "#{flag} #{inspect(value)}" end)
      |> Enum.join(", ")

    raise ArgumentError, "unknown or invalid option(s): #{formatted}"
  end
end
