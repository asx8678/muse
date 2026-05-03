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
            cli_ui: :repl,
            host: "127.0.0.1",
            port: 4000,
            workspace: nil,
            watch?: true,
            help?: false,
            verbose?: false

  @type cli_ui :: :repl | :tui | :none

  @type t :: %__MODULE__{
          cli?: boolean(),
          web?: boolean(),
          cli_ui: cli_ui(),
          host: String.t(),
          port: pos_integer(),
          workspace: String.t() | nil,
          watch?: boolean(),
          help?: boolean(),
          verbose?: boolean()
        }

  # -- OptionParser strict spec ------------------------------------------------
  # Keys use underscores (OptionParser normalizes --web-only → :web_only).
  # `watch: :boolean` auto-supports --no-watch (sets watch: false).

  @strict [
    no_web: :boolean,
    web_only: :boolean,
    no_cli: :boolean,
    tui: :boolean,
    repl: :boolean,
    port: :integer,
    host: :string,
    workspace: :string,
    verbose: :boolean,
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
    |> apply_verbose(parsed)
    |> apply_help(parsed)
    |> resolve_workspace!()
  end

  # -- Mode flags (cli? / web? / cli_ui) ---------------------------------------

  defp apply_mode_flags(opts, parsed) do
    opts
    |> apply_tui_flag(parsed)
    |> apply_repl_flag(parsed)
    |> apply_no_cli_flags(parsed)
    |> apply_no_web_flag(parsed)
    |> validate_mode_combination!(parsed)
  end

  defp apply_tui_flag(opts, parsed) do
    if parsed[:tui] == true, do: %{opts | cli_ui: :tui, cli?: true}, else: opts
  end

  defp apply_repl_flag(opts, parsed) do
    if parsed[:repl] == true, do: %{opts | cli_ui: :repl, cli?: true}, else: opts
  end

  defp apply_no_cli_flags(opts, parsed) do
    cond do
      parsed[:web_only] == true -> %{opts | cli?: false, cli_ui: :none, web?: true}
      parsed[:no_cli] == true -> %{opts | cli?: false, cli_ui: :none, web?: true}
      true -> opts
    end
  end

  defp apply_no_web_flag(opts, parsed) do
    if parsed[:no_web] == true, do: %{opts | web?: false}, else: opts
  end

  # -- Contradiction validation -------------------------------------------------

  defp validate_mode_combination!(opts, parsed) do
    tui? = is_true(parsed[:tui])
    repl? = is_true(parsed[:repl])
    web_only? = is_true(parsed[:web_only])
    no_cli? = is_true(parsed[:no_cli])
    no_web? = is_true(parsed[:no_web])

    # --tui conflicts with --repl
    if tui? and repl? do
      raise ArgumentError, "--tui and --repl cannot be used together"
    end

    # --tui conflicts with --web-only / --no-cli
    if tui? and web_only? do
      raise ArgumentError, "--tui and --web-only cannot be used together"
    end

    if tui? and no_cli? do
      raise ArgumentError, "--tui and --no-cli cannot be used together"
    end

    # --repl conflicts with --web-only / --no-cli
    if repl? and web_only? do
      raise ArgumentError, "--repl and --web-only cannot be used together"
    end

    if repl? and no_cli? do
      raise ArgumentError, "--repl and --no-cli cannot be used together"
    end

    # --web-only / --no-cli conflicts with --no-web
    if (web_only? or no_cli?) and no_web? do
      raise ArgumentError, "--web-only and --no-web cannot be used together"
    end

    opts
  end

  defp is_true(nil), do: false
  defp is_true(val), do: val == true

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

  defp apply_verbose(opts, parsed) do
    if parsed[:verbose] == true, do: %{opts | verbose?: true}, else: opts
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
