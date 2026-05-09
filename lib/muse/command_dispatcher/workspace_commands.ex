defmodule Muse.CommandDispatcher.WorkspaceCommands do
  @moduledoc """
  Workspace management command dispatchers.

  Handles `/workspace`, `/workspace list`, `/workspace switch`,
  `/workspace create`, and `/workspace info` commands.

  ## Lifecycle

  Called from `Muse.CommandDispatcher.dispatch/3` when the action
  is a workspace-related command. Returns the standard
  `{:ok, output, effects}` or `{:error, output, effects}` tuple.
  """

  alias Muse.{ActiveWorkspace, Backend, SessionStore, WorkspaceProfile}

  @doc "Dispatch workspace-related commands."
  @spec dispatch(atom(), String.t() | nil, map()) ::
          {:ok, String.t(), [tuple()]} | {:error, String.t(), [tuple()]} | :unknown
  def dispatch(:workspace, _args, context) do
    workspace = Map.get(context, :workspace) || Backend.safe_workspace_root()

    {:ok, "Workspace: #{workspace}", []}
  end

  def dispatch(:workspace_list, _args, _context) do
    case WorkspaceProfile.list_profiles() do
      {:ok, []} ->
        {:ok, "No workspace profiles configured. Use /workspace create <name> <path> to add one.",
         []}

      {:ok, profiles} ->
        lines = ["Workspace profiles:"]

        lines =
          lines ++
            Enum.map(profiles, fn p ->
              name = Map.get(p, "name") || Map.get(p, :name, "unknown")
              root = Map.get(p, "root_path") || Map.get(p, :root_path, "unknown")
              "  - #{name}: #{root}"
            end)

        {:ok, Enum.join(lines, "\n"), []}

      {:error, reason} ->
        {:error, "Failed to list profiles: #{inspect(reason)}", []}
    end
  end

  def dispatch(:workspace_switch, args, _context) do
    case parse_workspace_switch_args(args) do
      {:ok, name} ->
        if invalid_workspace_profile_name?(name) do
          {:error, invalid_workspace_profile_name_error(), []}
        else
          case ActiveWorkspace.switch(name) do
            {:ok, profile} ->
              root = Map.get(profile, :root_path) || Map.get(profile, "root_path", "unknown")

              sessions =
                Map.get(profile, :sessions_dir) || Map.get(profile, "sessions_dir", "unknown")

              msg =
                "Workspace '#{name}' is now active.\n" <>
                  "  Root: #{root}\n" <>
                  "  Sessions: #{sessions}\n" <>
                  "New sessions will use this workspace's session store."

              {:ok, msg, [{:toast, :success, "Workspace activated: #{name}"}]}

            {:error, :not_found} ->
              {:error,
               "Workspace profile '#{name}' not found. Use /workspace list to see available profiles.",
               []}

            {:error, {:invalid_profile_name, _name}} ->
              {:error, invalid_workspace_profile_name_error(), []}

            {:error, reason} ->
              {:error, "Failed to switch workspace: #{safe_workspace_switch_error(reason)}", []}
          end
        end

      {:error, :usage} ->
        {:error, "Error: usage: /workspace switch <name>", []}
    end
  end

  def dispatch(:workspace_create, args, _context) do
    case parse_workspace_create_args(args) do
      {:ok, name, root_path} ->
        case WorkspaceProfile.create(name: name, root_path: root_path) do
          {:ok, profile} ->
            msg =
              "Workspace profile '#{name}' created.\n  Root: #{profile.root_path}\n  Sessions: #{profile.sessions_dir}"

            {:ok, msg, [{:toast, :success, "Workspace created: #{name}"}]}

          {:error, {:invalid_profile_name, _n}} ->
            {:error, invalid_workspace_profile_name_error(), []}

          {:error, :name_required} ->
            {:error, "Profile name is required.", []}

          {:error, :root_path_required} ->
            {:error, "Root path is required.", []}

          {:error, reason} ->
            {:error, "Failed to create workspace: #{inspect(reason)}", []}
        end

      {:error, :usage} ->
        {:error, "Error: usage: /workspace create <name> <root_path>", []}
    end
  end

  def dispatch(:workspace_info, _args, context) do
    active = Backend.safe_active_workspace()
    workspace = Map.get(context, :workspace) || active.root_path || Backend.safe_workspace_root()
    sessions_dir = active.store_base_dir || WorkspaceProfile.sessions_dir_from_root(workspace)

    session_count =
      case SessionStore.list_sessions(sessions_dir) do
        {:ok, ids} -> length(ids)
        _ -> 0
      end

    active_info =
      try do
        case Process.whereis(Muse.ActiveWorkspace) do
          nil ->
            ""

          pid ->
            if Process.alive?(pid) do
              aw = Muse.ActiveWorkspace.get()

              if aw.profile_name do
                "\n  Active profile: #{aw.profile_name}\n  Active store: #{aw.store_base_dir}"
              else
                "\n  Active profile: (default)\n  Active store: #{aw.store_base_dir}"
              end
            else
              ""
            end
        end
      rescue
        _ -> ""
      end

    info = """
    Workspace info:
    Root: #{workspace}
    Sessions dir: #{sessions_dir}
    Session count: #{session_count}#{active_info}
    """

    {:ok, info, []}
  end

  def dispatch(_action, _args, _context), do: :unknown

  # -- Private helpers ----------------------------------------------------------

  defp parse_workspace_switch_args(nil), do: {:error, :usage}
  defp parse_workspace_switch_args(""), do: {:error, :usage}

  defp parse_workspace_switch_args(args) do
    name = String.trim(args)
    if name == "", do: {:error, :usage}, else: {:ok, name}
  end

  defp parse_workspace_create_args(nil), do: {:error, :usage}
  defp parse_workspace_create_args(""), do: {:error, :usage}

  defp parse_workspace_create_args(args) do
    parts = String.split(String.trim(args), ~r/\s+/, parts: 2)

    case parts do
      [name, root_path] when name != "" and root_path != "" ->
        {:ok, String.trim(name), String.trim(root_path)}

      [name] when name != "" ->
        {:error, :usage}

      _ ->
        {:error, :usage}
    end
  end

  defp invalid_workspace_profile_name?(name) when is_binary(name) do
    name == "" or name in [".", ".."] or String.contains?(name, ["/", "\\", <<0>>])
  end

  defp invalid_workspace_profile_name?(_name), do: true

  defp invalid_workspace_profile_name_error do
    "Invalid profile name. Names must be non-empty strings without /, \\, NUL bytes, or reserved values (. ..)."
  end

  defp safe_workspace_switch_error(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_workspace_switch_error(reason) when is_binary(reason) do
    Muse.Prompt.Redactor.preview_text(reason, max_length: 120)
  end

  defp safe_workspace_switch_error(_reason), do: "unexpected workspace error"
end
