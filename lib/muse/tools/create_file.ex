defmodule Muse.Tools.CreateFile do
  @moduledoc """
  Write tool: create a new text file in the workspace.

  Binary content is blocked. Secret and ignored paths are blocked.
  Content size is capped at 500,000 bytes. Parent directories
  are created automatically if they don't exist.

  Uses `Muse.Workspace.safe_resolve!/2` for path safety, and
  `Muse.Tool.SafeText` for binary/UTF-8 validation.

  ## Output format

      %{
        path: "lib/muse/new_module.ex",
        byte_size: 1234,
        metadata: %{created: true}
      }
  """

  alias Muse.Tool.Result
  alias Muse.Tool.SafeText

  @max_bytes 500_000

  @doc """
  Execute the create_file tool.

  ## Arguments

    * `"path"` — relative file path within workspace (required)
    * `"content"` — text content to write (required)

  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, context) do
    workspace = Map.get(context, :workspace, "")

    if not is_binary(workspace) or workspace == "" do
      Result.error("create_file", "workspace is required in context")
    else
      do_execute(args, workspace)
    end
  end

  defp do_execute(args, workspace) do
    with {:ok, path} <- require_path(args),
         {:ok, content} <- require_content(args),
         :ok <- check_content_size(content),
         :ok <- validate_text_content(content),
         {:ok, resolved} <- safe_resolve(path, workspace),
         :ok <- check_not_directory(resolved),
         :ok <- ensure_parent_dirs(resolved),
         :ok <- write_file(resolved, content) do
      Result.ok("create_file", %{
        path: path,
        byte_size: byte_size(content),
        metadata: %{created: true}
      })
    else
      {:error, reason} ->
        Result.error("create_file", reason)
    end
  end

  defp require_path(args) do
    case Map.get(args, "path") do
      nil -> {:error, "path is required"}
      "" -> {:error, "path is required"}
      path when is_binary(path) -> {:ok, path}
      _ -> {:error, "path must be a string"}
    end
  end

  defp require_content(args) do
    case Map.get(args, "content") do
      nil -> {:error, "content is required"}
      content when is_binary(content) -> {:ok, content}
      _ -> {:error, "content must be a string"}
    end
  end

  defp check_content_size(content) do
    if byte_size(content) > @max_bytes do
      {:error, "content exceeds maximum size of #{@max_bytes} bytes"}
    else
      :ok
    end
  end

  defp validate_text_content(content) do
    case SafeText.classify(content) do
      :text ->
        :ok

      :binary_file ->
        {:error, "binary content is not supported; only text content may be written"}

      :invalid_utf8 ->
        {:error, "content contains invalid UTF-8 and cannot be written as text"}

      :unsafe_text ->
        {:error, "content contains excessive control characters and may be binary"}
    end
  end

  defp safe_resolve(path, workspace) do
    try do
      {:ok, Muse.Workspace.safe_resolve!(path, workspace, [])}
    rescue
      ArgumentError -> {:error, "path escapes workspace or violates safety rules"}
    end
  end

  defp check_not_directory(path) do
    if File.dir?(path) do
      {:error, "path is a directory, not a file"}
    else
      :ok
    end
  end

  defp ensure_parent_dirs(resolved) do
    dir = Path.dirname(resolved)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create parent directories: #{inspect(reason)}"}
    end
  end

  defp write_file(resolved, content) do
    case File.write(resolved, content) do
      :ok -> :ok
      {:error, :eacces} -> {:error, "permission denied"}
      {:error, :enospc} -> {:error, "no space left on device"}
      {:error, reason} -> {:error, "file write error: #{inspect(reason)}"}
    end
  end
end
