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

  ## Registered write tools

    * `create_file` — create a new text file in the workspace (Coding Muse only)

  ## Registered read-only tools

    * `list_files` — list workspace files
    * `read_file` — read file contents
    * `repo_search` — search file contents
    * `git_status` — git status
    * `git_diff_readonly` — git diff (read-only)
    * `ask_user_question` — ask the user a question
    * `list_muses` — list available Muse profiles
    * `list_skills` — list available skills
    * `query_matrix` — search the project matrix for relevant files
    * `get_project_soul` — return project-level architecture summary
    * `load_workspace_files` — load files into the in-memory VFS

  ## Registered proposal tools

    * `patch_propose` — propose a patch without applying (Coding Muse only)

  ## Registered apply/rollback tools

    * `patch_apply` — apply an approved patch with checkpoint protection (Coding Muse only)
    * `rollback_checkpoint` — rollback a checkpoint to restore workspace (Coding Muse only)

  ## Registered test tool

    * `test_runner` — run predefined safe test command presets (Testing Muse only)

  ## Registered sub-agent tool

    * `spawn_sub_agents` — spawn worker agents for parallel tasks (Coding Muse only)

  ## Blocked tool names

  These tool names are explicitly recognized as dangerous. The runner blocks
  them instead of accidentally treating them as executable:

    * `write_file`, `replace_in_file`, `delete_file`
    * `shell_command`, `network_call`, `remote_execution`

  `patch_propose`, `patch_apply`, and `rollback_checkpoint` are **not** blocked —
  they are registered tools with runtime authorization gating.

  Destructive-looking unknown tool names (for example `apply_patch` or
  `run_shell`) are also treated as blocked so a provider cannot bypass the
  read-only surface by inventing a new write/shell/network-shaped name.
  Registered tools are never blocked, even if their name matches a
  destructive shape pattern.

  No dynamic atom creation from model input — all tool names are
  compile-time strings.
  """

  alias Muse.Tool.Spec

  # -- Blocked tool names (write/shell/network/delete/remote) --------------------

  @blocked_tool_names [
    "write_file",
    "replace_in_file",
    "delete_file",
    "shell_command",
    "network_call",
    "remote_execution"
  ]

  @blocked_tool_tokens MapSet.new([
                         "write",
                         "replace",
                         "delete",
                         "remove",
                         "rm",
                         "patch",
                         "shell",
                         "command",
                         "exec",
                         "execute",
                         "network",
                         "remote",
                         "http",
                         "https",
                         "curl",
                         "wget",
                         "request"
                       ])

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

  @patch_propose_spec Spec.new!(
                        name: "patch_propose",
                        description:
                          "Propose a patch by providing a unified diff. The patch is validated, hashed, and stored as a proposal. No files are written or modified. Requires an approved plan before use.",
                        handler: Muse.Tools.PatchPropose,
                        input_schema: %{
                          type: "object",
                          properties: %{
                            diff: %{
                              type: "string",
                              description: "Unified diff content to propose (required)"
                            },
                            summary: %{
                              type: "string",
                              description:
                                "Human-readable summary of the proposed changes (optional)"
                            },
                            affected_files: %{
                              type: "array",
                              items: %{type: "string"},
                              description:
                                "List of affected file paths (optional; parsed from diff if absent)"
                            }
                          },
                          required: ["diff"]
                        },
                        kind: :patch,
                        risk: :medium,
                        permission: :patch,
                        allowed_roles: [:coding],
                        allowed_muses: [:coding],
                        requires_approval: true,
                        output_limit: 20_000
                      )

  @patch_apply_spec Spec.new!(
                      name: "patch_apply",
                      description:
                        "Apply an approved patch to the workspace with checkpoint protection. Creates a checkpoint before applying, validates patch approval, and re-validates the diff. Only Coding Muse with an approved plan and matching patch approval may call this.",
                      handler: Muse.Tools.PatchApply,
                      input_schema: %{
                        type: "object",
                        properties: %{
                          patch_id: %{
                            type: "string",
                            description:
                              "The approved patch ID to apply (optional if patch_hash is provided)"
                          },
                          patch_hash: %{
                            type: "string",
                            description:
                              "The approved patch content hash (optional if patch_id is provided)"
                          }
                        }
                      },
                      kind: :write,
                      risk: :high,
                      permission: :patch,
                      allowed_roles: [:coding],
                      allowed_muses: [:coding],
                      requires_approval: true,
                      output_limit: 20_000
                    )

  @rollback_checkpoint_spec Spec.new!(
                              name: "rollback_checkpoint",
                              description:
                                "Rollback a checkpoint to restore the workspace to its pre-apply state. Only Coding Muse may rollback checkpoints belonging to the current session and active plan.",
                              handler: Muse.Tools.RollbackCheckpoint,
                              input_schema: %{
                                type: "object",
                                properties: %{
                                  checkpoint_id: %{
                                    type: "string",
                                    description: "The checkpoint ID to rollback (required)"
                                  }
                                },
                                required: ["checkpoint_id"]
                              },
                              kind: :write,
                              risk: :high,
                              permission: :restore_checkpoint,
                              allowed_roles: [:coding],
                              allowed_muses: [:coding],
                              requires_approval: true,
                              output_limit: 10_000
                            )

  @query_matrix_spec Spec.new!(
                       name: "query_matrix",
                       description:
                         "Search the project matrix to find relevant files by topic, module name, or functionality. Returns a ranked list with summaries and relevance scores.",
                       handler: Muse.Tools.QueryMatrix,
                       input_schema: %{
                         type: "object",
                         properties: %{
                           query: %{
                             type: "string",
                             description: "Search terms for finding relevant files (required)"
                           },
                           max_results: %{
                             type: "integer",
                             description:
                               "Maximum number of results to return (default: 10, max: 50)"
                           }
                         },
                         required: ["query"]
                       },
                       kind: :read,
                       risk: :low,
                       permission: :read,
                       allowed_roles: [:planning, :coding],
                       allowed_muses: [:planning, :coding],
                       requires_approval: false,
                       output_limit: 20_000
                     )

  @get_project_soul_spec Spec.new!(
                           name: "get_project_soul",
                           description:
                             "Return the project-level architecture summary (~500 words) including purpose, key modules, namespaces, and file types. Useful for understanding the project before querying specific files.",
                           handler: Muse.Tools.GetProjectSoul,
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
                           output_limit: 10_000
                         )

  @load_workspace_files_spec Spec.new!(
                               name: "load_workspace_files",
                               description:
                                 "Load specific files into the in-memory VFS for editing. Returns file content and metadata. Idempotent — loading a file already in VFS returns cached content.",
                               handler: Muse.Tools.LoadWorkspaceFiles,
                               input_schema: %{
                                 type: "object",
                                 properties: %{
                                   files: %{
                                     type: "array",
                                     items: %{type: "string"},
                                     description:
                                       "List of relative file paths to load into VFS (required)"
                                   },
                                   purpose: %{
                                     type: "string",
                                     description:
                                       "Why these files are needed (optional, for observability)"
                                   }
                                 },
                                 required: ["files"]
                               },
                               kind: :read,
                               risk: :low,
                               permission: :read,
                               allowed_roles: [:planning, :coding],
                               allowed_muses: [:planning, :coding],
                               requires_approval: false,
                               output_limit: 100_000
                             )

  @test_runner_spec Spec.new!(
                      name: "test_runner",
                      description:
                        "Run predefined safe test command presets (mix format --check-formatted, mix compile --warnings-as-errors, mix test, mix test <file>). Arbitrary shell commands are blocked. Only Testing Muse may use this tool.",
                      handler: Muse.Tools.TestRunner,
                      input_schema: %{
                        type: "object",
                        properties: %{
                          command: %{
                            type: "string",
                            description:
                              "Safe preset name: mix_format_check, mix_compile, mix_test, or mix_test_file (required)"
                          },
                          file_path: %{
                            type: "string",
                            description:
                              "Workspace-relative test file path for mix_test_file (must end in _test.exs, must be under test/)"
                          }
                        },
                        required: ["command"]
                      },
                      kind: :shell,
                      risk: :medium,
                      permission: :test,
                      allowed_roles: [:testing],
                      allowed_muses: [:testing],
                      requires_approval: false,
                      output_limit: 50_000
                    )

  @create_file_spec Spec.new!(
                      name: "create_file",
                      description:
                        "Create a new text file in the workspace. Binary content is blocked. Parent directories are created automatically. Respects secret and ignored path rules. Content size is capped at 500KB.",
                      handler: Muse.Tools.CreateFile,
                      input_schema: %{
                        type: "object",
                        properties: %{
                          path: %{
                            type: "string",
                            description: "Relative file path within the workspace (required)"
                          },
                          content: %{
                            type: "string",
                            description: "Text content to write to the file (required)"
                          }
                        },
                        required: ["path", "content"]
                      },
                      kind: :write,
                      risk: :medium,
                      permission: :write,
                      allowed_roles: [:coding],
                      allowed_muses: [:coding],
                      requires_approval: true,
                      output_limit: 5_000
                    )

  @spawn_sub_agents_spec Spec.new!(
                           name: "spawn_sub_agents",
                           description:
                             "Spawn worker agents (coder, reviewer, scout) to perform tasks in parallel. Returns immediately with worker IDs; results arrive asynchronously. Each session has its own isolated worker pool.",
                           handler: Muse.Tools.SpawnSubAgents,
                           input_schema: %{
                             type: "object",
                             properties: %{
                               workers: %{
                                 type: "array",
                                 description: "List of worker specifications to spawn (required)",
                                 items: %{
                                   type: "object",
                                   properties: %{
                                     type: %{
                                       type: "string",
                                       description:
                                         "Worker type: coder, reviewer, or scout (required)",
                                       enum: ["coder", "reviewer", "scout"]
                                     },
                                     task_id: %{
                                       type: "string",
                                       description: "Unique identifier for this worker (required)"
                                     },
                                     instructions: %{
                                       type: "string",
                                       description:
                                         "Detailed task description for the worker (required)"
                                     },
                                     files: %{
                                       type: "array",
                                       items: %{type: "string"},
                                       description:
                                         "List of workspace-relative file paths the worker should access"
                                     },
                                     max_duration_ms: %{
                                       type: "integer",
                                       description:
                                         "Per-worker timeout in milliseconds (default: 300000)"
                                     }
                                   },
                                   required: ["type", "task_id", "instructions"]
                                 }
                               }
                             },
                             required: ["workers"]
                           },
                           kind: :shell,
                           risk: :medium,
                           permission: :shell,
                           allowed_roles: [:coding],
                           allowed_muses: [:coding],
                           requires_approval: false,
                           output_limit: 10_000
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
    "list_skills",
    "query_matrix",
    "get_project_soul",
    "load_workspace_files",
    "patch_propose",
    "patch_apply",
    "rollback_checkpoint",
    "test_runner",
    "spawn_sub_agents",
    "create_file"
  ]

  @specs_by_name %{
    "list_files" => @list_files_spec,
    "read_file" => @read_file_spec,
    "repo_search" => @repo_search_spec,
    "git_status" => @git_status_spec,
    "git_diff_readonly" => @git_diff_readonly_spec,
    "ask_user_question" => @ask_user_question_spec,
    "list_muses" => @list_muses_spec,
    "list_skills" => @list_skills_spec,
    "query_matrix" => @query_matrix_spec,
    "get_project_soul" => @get_project_soul_spec,
    "load_workspace_files" => @load_workspace_files_spec,
    "patch_propose" => @patch_propose_spec,
    "patch_apply" => @patch_apply_spec,
    "rollback_checkpoint" => @rollback_checkpoint_spec,
    "test_runner" => @test_runner_spec,
    "spawn_sub_agents" => @spawn_sub_agents_spec,
    "create_file" => @create_file_spec
  }

  # -- Public API ---------------------------------------------------------------

  @doc """
  Returns all registered tool specs in deterministic order.

  ## Examples

      iex> length(Muse.Tool.Registry.all())
      17

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
       "git_diff_readonly", "ask_user_question", "list_muses", "list_skills",
       "query_matrix", "get_project_soul", "load_workspace_files"]

      iex> specs = Muse.Tool.Registry.specs_for_muse(:coding)
      iex> Enum.map(specs, & &1.name)
      ["list_files", "read_file", "repo_search", "git_status",
       "git_diff_readonly", "query_matrix", "get_project_soul", "load_workspace_files",
       "patch_propose", "patch_apply", "create_file"]

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
      11
      iex> hd(schemas)[:name]
      "list_files"

      iex> schemas = Muse.Tool.Registry.provider_schemas(:coding)
      iex> names = Enum.map(schemas, & &1[:name])
      iex> true = "patch_propose" in names
      iex> true = "patch_apply" in names
      iex> false = "rollback_checkpoint" in names
      iex> false = "test_runner" in names

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

      iex> Muse.Tool.Registry.blocked_tool?("patch_propose")
      false

      iex> Muse.Tool.Registry.blocked_tool?("patch_apply")
      false

  """
  @spec blocked_tool?(String.t()) :: boolean()
  def blocked_tool?(name) when is_binary(name) do
    # Registered tools are never blocked, even if their name tokens
    # match the destructive shape heuristic. This allows `patch_propose`
    # (tokens include "patch") to be a registered tool that is not blocked.
    name not in @ordered_names and
      (name in @blocked_tool_names or destructive_tool_shape?(name))
  end

  defp destructive_tool_shape?(name) do
    name
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.any?(&MapSet.member?(@blocked_tool_tokens, &1))
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
       "git_diff_readonly", "ask_user_question", "list_muses", "list_skills",
       "query_matrix", "get_project_soul", "load_workspace_files",
       "patch_propose", "patch_apply", "rollback_checkpoint", "test_runner",
       "spawn_sub_agents", "create_file"]

  """
  @spec tool_names() :: [String.t()]
  def tool_names, do: @ordered_names
end
