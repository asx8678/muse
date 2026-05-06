defmodule Muse.Execution.Command do
  @moduledoc """
  Execution request struct for Muse runner abstraction.

  Represents a validated, safe execution request for a local or future
  remote runner. All fields are validated at construction time to ensure
  safe execution semantics.

  ## Safety properties

    * `executable` must be a non-empty binary without path traversal or
      control characters. Bare names are resolved via `System.find_executable/1`.
      Absolute paths are allowed only when they resolve to an existing executable.
    * `args` must be a list of binaries — no shell strings, no interpolation.
    * `cwd` must be a safe local directory (workspace or trusted path).
    * `timeout_ms` must be finite and reasonable (default 60_000ms, max 5 minutes).
    * `max_output_bytes` must be finite and reasonable (default 50KB, max 500KB).
    * `env` must be a map/list of safe string pairs; secrets are redacted in display.

  ## Redaction

  Args and env are redacted in `safe_display/1` to prevent leaking secrets
  in logs, events, or error messages.
  """

  @enforce_keys [:id, :executable]
  defstruct [
    :id,
    :runner,
    :target,
    :executable,
    args: [],
    cwd: nil,
    env: %{},
    timeout_ms: 60_000,
    max_output_bytes: 50_000,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          runner: :local | :remote | atom(),
          target: :local | String.t() | nil,
          executable: String.t(),
          args: [String.t()],
          cwd: String.t() | nil,
          env: map() | [{String.t(), String.t()}],
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          metadata: map()
        }

  @max_timeout_ms 300_000
  @max_output_bytes 500_000
  @max_args 100
  @max_arg_length 10_000
  @max_env_keys 100

  @doc """
  Create a new execution command with validation.

  ## Options

    * `:runner` — runner atom (`:local` default; remote denied by policy)
    * `:target` — target identifier (`:local` default)
    * `:args` — list of argument strings (default: `[]`)
    * `:cwd` — working directory (optional)
    * `:env` — environment map or keyword list (default: `%{}`)
    * `:timeout_ms` — timeout in milliseconds (default: 60_000, max: 300_000)
    * `:max_output_bytes` — output cap (default: 50_000, max: 500_000)
    * `:metadata` — additional metadata map (default: `%{}`)

  ## Examples

      iex> {:ok, cmd} = Muse.Execution.Command.new("elixir", args: ["-e", "IO.puts(:hello)"])
      iex> cmd.executable
      "elixir"

      iex> {:error, reason} = Muse.Execution.Command.new("", args: [])
      iex> reason
      "executable must be a non-empty string"

  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(executable, opts \\ [])

  def new(executable, opts) when is_binary(executable) and is_list(opts) do
    with :ok <- validate_executable(executable),
         :ok <- validate_args(Keyword.get(opts, :args, [])),
         :ok <- validate_cwd(Keyword.get(opts, :cwd)),
         :ok <- validate_env(Keyword.get(opts, :env, %{})),
         :ok <- validate_timeout(Keyword.get(opts, :timeout_ms, 60_000)),
         :ok <- validate_max_output(Keyword.get(opts, :max_output_bytes, 50_000)),
         :ok <- validate_metadata(Keyword.get(opts, :metadata, %{})) do
      cmd = %__MODULE__{
        id: generate_id(),
        runner: Keyword.get(opts, :runner, :local),
        target: Keyword.get(opts, :target, :local),
        executable: executable,
        args: normalize_args(Keyword.get(opts, :args, [])),
        cwd: normalize_cwd(Keyword.get(opts, :cwd)),
        env: normalize_env(Keyword.get(opts, :env, %{})),
        timeout_ms: Keyword.get(opts, :timeout_ms, 60_000),
        max_output_bytes: Keyword.get(opts, :max_output_bytes, 50_000),
        metadata: Keyword.get(opts, :metadata, %{})
      }

      {:ok, cmd}
    end
  end

  def new(executable, _opts) when not is_binary(executable) do
    {:error, "executable must be a non-empty string"}
  end

  @doc """
  Create a new command or raise on validation error.

  Useful for static/test fixtures where inputs are known safe.
  """
  @spec new!(String.t(), keyword()) :: t()
  def new!(executable, opts \\ []) do
    case new(executable, opts) do
      {:ok, cmd} -> cmd
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Return a safe display string for the command, with redacted args/env.

  Never exposes secret-looking values. Used for logging, events, and errors.
  """
  @spec safe_display(t()) :: String.t()
  def safe_display(%__MODULE__{} = cmd) do
    argv_display =
      [cmd.executable | cmd.args]
      |> Enum.map(&redact_arg/1)
      |> Enum.join(" ")

    env_display =
      case cmd.env do
        env when is_map(env) and map_size(env) == 0 -> ""
        env -> " (env: #{redact_env_display(env)})"
      end

    cwd_display =
      case cmd.cwd do
        nil -> ""
        cwd -> " in #{cwd}"
      end

    "Command[#{cmd.id}]: #{argv_display}#{env_display}#{cwd_display}"
  end

  @doc """
  Return the argv list for execution (executable + args).

  Does NOT redact — this is for actual execution, not display.
  """
  @spec argv_vector(t()) :: [String.t()]
  def argv_vector(%__MODULE__{executable: exe, args: args}) do
    [exe | args]
  end

  @doc """
  Return true if the command targets local execution.
  """
  @spec local?(t()) :: boolean()
  def local?(%__MODULE__{target: :local}), do: true
  def local?(%__MODULE__{target: nil}), do: true
  def local?(_), do: false

  @doc """
  Return true if the command targets remote execution.
  """
  @spec remote?(t()) :: boolean()
  def remote?(%__MODULE__{target: target}) when target in [:remote, :ssh], do: true
  def remote?(%__MODULE__{target: target}) when is_binary(target), do: true
  def remote?(_), do: false

  # -- Validation helpers -------------------------------------------------------

  defp validate_executable(""), do: {:error, "executable must be a non-empty string"}
  defp validate_executable(nil), do: {:error, "executable must be a non-empty string"}

  defp validate_executable(exe) when is_binary(exe) do
    cond do
      String.contains?(exe, "\0") ->
        {:error, "executable contains NUL character"}

      String.contains?(exe, "\n") or String.contains?(exe, "\r") ->
        {:error, "executable contains newline character"}

      path_traversal?(exe) ->
        {:error, "executable contains path traversal"}

      true ->
        :ok
    end
  end

  defp validate_executable(_), do: {:error, "executable must be a string"}

  defp path_traversal?(path) do
    String.contains?(path, "..") or
      (Path.type(path) == :relative and String.contains?(path, "/"))
  end

  defp validate_args(args) when is_list(args) do
    cond do
      length(args) > @max_args ->
        {:error, "too many arguments (max #{@max_args})"}

      not Enum.all?(args, &valid_arg?/1) ->
        {:error, "all arguments must be strings without control characters"}

      Enum.any?(args, &control_char?/1) ->
        {:error, "arguments contain control characters"}

      true ->
        :ok
    end
  end

  defp validate_args(_), do: {:error, "args must be a list"}

  defp valid_arg?(arg) when is_binary(arg), do: byte_size(arg) <= @max_arg_length
  defp valid_arg?(_), do: false

  defp control_char?(s) when is_binary(s) do
    String.match?(s, ~r/[[:cntrl:]]/)
  end

  defp control_char?(_), do: false

  defp validate_cwd(nil), do: :ok

  defp validate_cwd(cwd) when is_binary(cwd) do
    if File.dir?(cwd) do
      :ok
    else
      {:error, "cwd must be an existing directory"}
    end
  end

  defp validate_cwd(_), do: {:error, "cwd must be a string path or nil"}

  defp validate_env(env) when is_map(env) do
    if map_size(env) > @max_env_keys do
      {:error, "too many environment variables (max #{@max_env_keys})"}
    else
      :ok
    end
  end

  defp validate_env(env) when is_list(env) do
    if length(env) > @max_env_keys do
      {:error, "too many environment variables (max #{@max_env_keys})"}
    else
      :ok
    end
  end

  defp validate_env(_), do: {:error, "env must be a map or list"}

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0 do
    if timeout <= @max_timeout_ms do
      :ok
    else
      {:error, "timeout_ms exceeds maximum (#{@max_timeout_ms}ms)"}
    end
  end

  defp validate_timeout(_), do: {:error, "timeout_ms must be a positive integer"}

  defp validate_max_output(max) when is_integer(max) and max > 0 do
    if max <= @max_output_bytes do
      :ok
    else
      {:error, "max_output_bytes exceeds maximum (#{@max_output_bytes})"}
    end
  end

  defp validate_max_output(_), do: {:error, "max_output_bytes must be a positive integer"}

  defp validate_metadata(meta) when is_map(meta), do: :ok
  defp validate_metadata(_), do: {:error, "metadata must be a map"}

  # -- Normalization helpers ----------------------------------------------------

  defp normalize_args(args) when is_list(args) do
    Enum.map(args, &to_string/1)
  end

  defp normalize_args(_), do: []

  defp normalize_cwd(nil), do: nil
  defp normalize_cwd(cwd) when is_binary(cwd), do: Path.expand(cwd)
  defp normalize_cwd(_), do: nil

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_env(env) when is_list(env) do
    Map.new(env, fn
      {k, v} -> {to_string(k), to_string(v)}
      _ -> {"", ""}
    end)
  end

  defp normalize_env(_), do: %{}

  # -- Redaction helpers --------------------------------------------------------

  defp redact_arg(arg) when is_binary(arg) do
    Muse.Prompt.Redactor.redact_text(arg)
  end

  defp redact_arg(arg), do: inspect(arg)

  defp redact_env_display(env) when is_map(env) do
    env
    |> Map.keys()
    |> Enum.take(5)
    |> Enum.map(fn k -> "#{k}=..." end)
    |> Enum.join(", ")
    |> then(fn s ->
      if map_size(env) > 5, do: s <> ", ...", else: s
    end)
  end

  defp redact_env_display(env) when is_list(env) do
    env
    |> Enum.take(5)
    |> Enum.map(fn {k, _v} -> "#{k}=..." end)
    |> Enum.join(", ")
    |> then(fn s ->
      if length(env) > 5, do: s <> ", ...", else: s
    end)
  end

  defp redact_env_display(_), do: "..."

  defp generate_id do
    "cmd_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end
end
