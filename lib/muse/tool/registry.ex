defmodule Muse.Tool.Registry do
  @moduledoc """
  Deterministic built-in registry of tool specifications.

  All tools are defined at compile time. Lookup is by name string.
  The registry provides:

    * `get/1` — spec lookup by name string
    * `all/0` — all registered specs in deterministic order
    * `specs_for_muse/1` — filtered specs for a given Muse profile
    * `provider_schemas/1` — provider-ready JSON schema maps for prompt assembly
    * `known_tool?/1` — check if a name is a registered tool (not a blocked name)
    * `blocked_tool?/1` — check if a name is a known dangerous/blocked tool

  ## Registered read-only tools

    * `list_files` — list workspace files
    * `read_file` — read file contents
    * `repo_search` — search file contents
    * `git_status` — git status
    * `git_diff_readonly` — git diff (read-only)
    * `ask_user_question` — ask the user a question
    * `list_muses` — list available Muse profiles
    * `list_skills` — list available skills

  ## Blocked tool names

  These tool names are explicitly recognized as dangerous. The runner blocks
  them instead of accidentally treating them as executable:

    * `write_file`, `replace_in_file`, `delete_file`, `patch_apply`
    * `shell_command`, `network_call`, `remote_execution`

  No dynamic atom creation from model input — all tool names are
  compile-time strings.
  """

  alias Muse.Tool.Spec

  # -- Blocked tool names (write/shell/network/delete/remote) --------------------

  @blocked_tool_names [
    "write_file",
    "replace_in_file",
    "delete_file",
    "patch_apply",
    "shell_command",
    "network_call",
    "remote_execution"
  ]

  # -- Read-only tool specs (compile-time) --------------------------------------

  @list_files_spec Spec.new!(
                     name: "list_files",
                     description:
                       "List files and directories in the workspace. Returns sorted entries with paths relative to workspace root. Respects ignored and secret path rules.",
                     handler: Muse.Tools.ListFiles,
                     input_schema: %{
                       type: "object",
                       properties: %{
                         path: %{
                           type: "string",
                           description:
                             "Relative directory path within the workspace (default: root)"
                         },
                         max_entries: %{
                           type: "integer",
                           description: "Maximum number of entries to return (default: 500)"
                         },
                         allow_hidden: %{
                           type: "boolean",
                           description: "Whether to include hidden files (default: false)"
                         }
                       }
                     },
                     kind: :read,
                     risk: :low,
                     permission: :read,
                     allowed_roles: [:planning, :coding],
                     allowed_muses: [:planning, :coding],
                     requires_approval: false,
                     output_limit: 50_000
                   )

  @read_file_spec Spec.new!(
                    name: "read_file",
                    description:
                      "Read the contents of a text file in the workspace. Binary files are blocked. Supports line range selection. Respects secret and ignored path rules.",
                    handler: Muse.Tools.ReadFile,
                    input_schema: %{
                      type: "object",
                      properties: %{
                        path: %{
                          type: "string",
                          description: "Relative file path within the workspace (required)"
                        },
                        start_line: %{
                          type: "integer",
                          description: "First line to read (1-based)"
                        },
                        end_line: %{
                          type: "integer",
                          description: "Last line to read (inclusive)"
                        },
                        max_lines: %{
                          type: "integer",
                          description: "Maximum number of lines to return (default: 500)"
                        }
                      },
                      required: ["path"]
                    },
                    kind: :read,
                    risk: :low,
                    permission: :read,
                    allowed_roles: [:planning, :coding],
                    allowed_muses: [:planning, :coding],
                    requires_approval: false,
                    output_limit: 100_000
                  )

  @repo_search_spec Spec.new!(
                      name: "repo_search",
                      description:
                        "Search for text patterns across workspace files using a pure-Elixir scanner. Returns matching file paths and line excerpts. Respects ignored and secret path rules.",
                      handler: Muse.Tools.RepoSearch,
                      input_schema: %{
                        type: "object",
                        properties: %{
                          pattern: %{
                            type: "string",
                            description: "Text pattern to search for (required)"
                          },
                          max_results: %{
                            type: "integer",
                            description: "Maximum number of results to return (default: 50)"
                          },
                          file_pattern: %{
                            type: "string",
                            description: "Glob pattern to filter files (e.g. '*.ex', '*.exs')"
                          }
                        },
                        required: ["pattern"]
                      },
                      kind: :read,
                      risk: :low,
                      permission: :read,
                      allowed_roles: [:planning, :coding],
                      allowed_muses: [:planning, :coding],
                      requires_approval: false,
                      output_limit: 50_000
                    )

  @git_status_spec Spec.new!(
                     name: "git_status",
                     description:
                       "Show the working tree status via git status. Reports branch, clean/dirty state, and changed files. Constrained to workspace; no model-controlled args.",
                     handler: Muse.Tools.GitStatus,
                     input_schema: %{
                       type: "object",
                       properties: %{}
                     },
                     kind: :read,
                     risk: :low,
                     permission: :read,
                     allowed_roles: [:planning, :coding],
                     allowed_muses: [:planning, :coding],
                     requires_approval: false,
                     output_limit: 20_000
                   )

  @git_diff_readonly_spec Spec.new!(
                            name: "git_diff_readonly",
                            description:
                              "Show git diff output (read-only). Supports optional workspace-relative path and cached flag. No write commands; output is capped and redacted.",
                            handler: Muse.Tools.GitDiffReadonly,
                            input_schema: %{
                              type: "object",
                              properties: %{
                                path: %{
                                  type: "string",
                                  description: "Workspace-relative path to diff (optional)"
                                },
                                cached: %{
                                  type: "boolean",
                                  description:
                                    "Show staged changes instead of working tree (default: false)"
                                }
                              }
                            },
                            kind: :read,
                            risk: :low,
                            permission: :read,
                            allowed_roles: [:planning, :coding],
                            allowed_muses: [:planning, :coding],
                            requires_approval: false,
                            output_limit: 100_000
                          )

  @ask_user_question_spec Spec.new!(
                            name: "ask_user_question",
                            description:
                              "Ask the user a clarifying question. Returns a non-blocking result (answered: false) since the model must wait for user input.",
                            handler: Muse.Tools.AskUserQuestion,
                            input_schema: %{
                              type: "object",
                              properties: %{
                                question: %{
                                  type: "string",
                                  description: "The question to ask the user (required)"
                                }
                              },
                              required: ["question"]
                            },
                            kind: :interactive,
                            risk: :low,
                            permission: :interactive,
                            allowed_roles: [:planning, :coding],
                            allowed_muses: [:planning, :coding],
                            requires_approval: false,
                            output_limit: 5_000
                          )

  @list_muses_spec Spec.new!(
                     name: "list_muses",
                     description:
                       "List available Muse profiles with safe summaries (id, display name, role, description, tools, permissions).",
                     handler: Muse.Tools.ListMuses,
                     input_schema: %{
                       type: "object",
                       properties: %{}
                     },
                     kind: :read,
                     risk: :low,
                     permission: :read,
                     allowed_roles: [:planning, :coding],
                     allowed_muses: [:planning, :coding],
                     requires_approval: false,
                     output_limit: 5_000
                   )

  @list_skills_spec Spec.new!(
                      name: "list_skills",
                      description:
                        "List available skills. Returns an empty deterministic list if no skill system is active.",
                      handler: Muse.Tools.ListSkills,
                      input_schema: %{
                        type: "object",
                        properties: %{}
                      },
                      kind: :read,
                      risk: :low,
                      permission: :read,
                      allowed_roles: [:planning, :coding],
                      allowed_muses: [:planning, :coding],
                      requires_approval: false,
                      output_limit: 2_000
                    )

  # -- Internal index -----------------------------------------------------------

  @ordered_names [
    "list_files",
    "read_file",
    "repo_search",
    "git_status",
    "git_diff_readonly",
    "ask_user_question",
    "list_muses",
    "list_skills"
  ]

  @specs_by_name %{
    "list_files" => @list_files_spec,
    "read_file" => @read_file_spec,
    "repo_search" => @repo_search_spec,
    "git_status" => @git_status_spec,
    "git_diff_readonly" => @git_diff_readonly_spec,
    "ask_user_question" => @ask_user_question_spec,
    "list_muses" => @list_muses_spec,
    "list_skills" => @list_skills_spec
  }

  # -- Public API ---------------------------------------------------------------

  @doc """
  Returns all registered tool specs in deterministic order.

  ## Examples

      iex> length(Muse.Tool.Registry.all())
      8

      iex> hd(Muse.Tool.Registry.all()).name
      "list_files"

  """
  @spec all() :: [Spec.t()]
  def all do
    Enum.map(@ordered_names, &Map.fetch!(@specs_by_name, &1))
  end

  @doc """
  Returns the tool spec with the given name, or `nil` if not found.

  Only returns specs for registered tools. Blocked/dangerous tool names
  return `nil` (use `blocked_tool?/1` to check).

  ## Examples

      iex> Muse.Tool.Registry.get("read_file").name
      "read_file"

      iex> Muse.Tool.Registry.get("write_file")
      nil

      iex> Muse.Tool.Registry.get("unknown_tool")
      nil

  """
  @spec get(String.t()) :: Spec.t() | nil
  def get(name) when is_binary(name) do
    Map.get(@specs_by_name, name)
  end

  @doc """
  Returns `{:ok, spec}` or `{:error, :not_found}`.

  ## Examples

      iex> Muse.Tool.Registry.fetch("read_file")
      {:ok, %Muse.Tool.Spec{name: "read_file"}}

      iex> Muse.Tool.Registry.fetch("shell_command")
      {:error, :not_found}

  """
  @spec fetch(String.t()) :: {:ok, Spec.t()} | {:error, :not_found}
  def fetch(name) do
    case get(name) do
      nil -> {:error, :not_found}
      spec -> {:ok, spec}
    end
  end

  @doc """
  Returns tool specs filtered for a given Muse profile.

  Only includes tools whose `allowed_muses` list includes the given muse_id
  AND whose names appear in the profile's `tools` list.

  ## Examples

      iex> specs = Muse.Tool.Registry.specs_for_muse(:planning)
      iex> Enum.map(specs, & &1.name)
      ["list_files", "read_file", "repo_search", "git_status",
       "git_diff_readonly", "ask_user_question", "list_muses", "list_skills"]

  """
  @spec specs_for_muse(atom()) :: [Spec.t()]
  def specs_for_muse(muse_id) when is_atom(muse_id) do
    profile = Muse.MuseRegistry.get(muse_id)
    profile_tools = if profile, do: profile.tools || [], else: []

    all()
    |> Enum.filter(fn spec ->
      muse_id in spec.allowed_muses and spec.name in profile_tools
    end)
  end

  @doc """
  Returns provider-ready JSON schema maps for the given Muse profile.

  Used by `Muse.Prompt.Assembler` and `Muse.Prompt.ModelPreparer` to
  build tool definitions for LLM requests.

  ## Examples

      iex> schemas = Muse.Tool.Registry.provider_schemas(:planning)
      iex> length(schemas)
      8
      iex> hd(schemas)[:name]
      "list_files"

  """
  @spec provider_schemas(atom()) :: [map()]
  def provider_schemas(muse_id) when is_atom(muse_id) do
    muse_id
    |> specs_for_muse()
    |> Enum.map(&Spec.to_provider_schema/1)
  end

  @doc """
  Returns provider-ready schemas for a list of tool name strings,
  excluding any blocked tools.

  This is the direct replacement for the PR05 `%{name: ..., type: "function"}`
  placeholder maps.
  """
  @spec provider_schemas_for_names([String.t()]) :: [map()]
  def provider_schemas_for_names(tool_names) when is_list(tool_names) do
    tool_names
    |> Enum.reject(&blocked_tool?/1)
    |> Enum.map(fn name ->
      case get(name) do
        nil ->
          %{
            "name" => name,
            :name => name,
            "type" => "function",
            "function" => %{"name" => name, "description" => "", "parameters" => %{}}
          }

        spec ->
          Spec.to_provider_schema(spec)
      end
    end)
  end

  @doc """
  Check if a name is a registered (known) tool.

  ## Examples

      iex> Muse.Tool.Registry.known_tool?("read_file")
      true

      iex> Muse.Tool.Registry.known_tool?("totally_unknown")
      false

  """
  @spec known_tool?(String.t()) :: boolean()
  def known_tool?(name) when is_binary(name) do
    Map.has_key?(@specs_by_name, name)
  end

  @doc """
  Check if a name is a known dangerous/blocked tool.

  Blocked tools are write/shell/network/delete/remote tools that must
  never be accidentally treated as executable.

  ## Examples

      iex> Muse.Tool.Registry.blocked_tool?("write_file")
      true

      iex> Muse.Tool.Registry.blocked_tool?("shell_command")
      true

      iex> Muse.Tool.Registry.blocked_tool?("read_file")
      false

  """
  @spec blocked_tool?(String.t()) :: boolean()
  def blocked_tool?(name) when is_binary(name) do
    name in @blocked_tool_names
  end

  @doc """
  Returns the list of blocked tool name strings.

  ## Examples

      iex> "write_file" in Muse.Tool.Registry.blocked_tool_names()
      true

  """
  @spec blocked_tool_names() :: [String.t()]
  def blocked_tool_names, do: @blocked_tool_names

  @doc """
  Returns the list of all registered tool name strings in deterministic order.

  ## Examples

      iex> Muse.Tool.Registry.tool_names()
      ["list_files", "read_file", "repo_search", "git_status",
       "git_diff_readonly", "ask_user_question", "list_muses", "list_skills"]

  """
  @spec tool_names() :: [String.t()]
  def tool_names, do: @ordered_names
end
