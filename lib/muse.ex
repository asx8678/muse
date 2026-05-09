defmodule Muse do
  @moduledoc """
  Muse — Minimal coding-runtime foundation.

  The primary public API for submitting user input and receiving assistant
  responses. Every submission is routed through `Muse.SessionRouter` to a
  per-session `Muse.SessionServer` that appends events to the global
  `Muse.State` log and returns an assistant response.

  In test/smoke environments, the fake provider is always used (no network
  calls). In dev/prod, submits can optionally route through a configured
  LLM provider by passing `opts` resolved from `Muse.RuntimeProvider.resolve_opts/0`.

  When queued self-healing issues exist, they are atomically claimed
  and attached as an event before the assistant response.
  """

  alias Muse.SessionRouter

  @doc """
  Submits a user message and returns an assistant response.

  Delegates to `Muse.SessionRouter.submit/4` with the `"default"` session
  id, which routes to a scoped `Muse.SessionServer`.

  The server creates a `:user_message` event from `source`, then runs a
  Conductor turn and appends events (including an `:assistant_message`) to
  `Muse.State`.

  If there are queued self-healing issues, `Muse.SelfHealingQueue.claim_queued/0`
  atomically transitions them to `:in_progress` and a `:queued_issues_attached`
  event is inserted between the user and assistant events.

  ## Options

    * `:provider_config` — resolved `Muse.LLM.ProviderConfig` struct
      (from `Muse.RuntimeProvider.resolve_opts/0`)
    * `:provider_env` — env map for Conductor provider resolution (legacy,
      prefer `:provider_config`; see `Muse.Conductor.resolve_provider_config/1`)
    * `:model_router_opts` — opts for `Muse.LLM.ModelRouter.resolve/3`
    * `:provider_module` — explicit provider module override
    * `:workspace` — workspace root override

  When no opts are provided (the default), the Conductor uses the fake
  provider. To route through a configured provider in dev/prod, pass
  opts from `Muse.RuntimeProvider.resolve_opts/0`.

  ## Examples

      # Default (fake provider, no network)
      {:ok, text} = Muse.submit(:cli, "hello")

      # With runtime provider opts (dev/prod only)
      {:ok, opts} = Muse.RuntimeProvider.resolve_opts()
      {:ok, text} = Muse.submit(:web, "explain this", opts)

  """
  @spec submit(atom(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, :turn_in_progress}
          | {:error, :submit_timeout}
          | {:error, term()}
  def submit(source, text, opts \\ [])
      when is_atom(source) and is_binary(text) and is_list(opts) do
    SessionRouter.submit(source, text, opts)
  end

  @doc """
  Non-blocking submit: starts a turn and returns immediately.

  Returns `{:ok, turn_id}` when the turn was successfully started, or
  `{:error, :turn_in_progress}` if a turn is already active.

  Unlike `submit/3`, this function does **not** block the caller.
  Turn progress and completion are communicated via `Muse.State`
  PubSub events (`:turn_started`, `:turn_completed`, `:turn_failed`,
  `:turn_cancelled`).  Use this for LiveView and other non-blocking
  callers; prefer `submit/3` for CLI/TUI paths that need the result.

  ## Options

  Same as `submit/3` (`:provider_config`, `:provider_env`,
  `:model_router_opts`, `:provider_module`, `:workspace`).

  ## Examples

      {:ok, turn_id} = Muse.start_submit(:web, "hello")
      # Listen for :turn_completed/:turn_failed/:turn_cancelled via PubSub
  """
  @spec start_submit(atom(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :turn_in_progress} | {:error, term()}
  def start_submit(source, text, opts \\ [])
      when is_atom(source) and is_binary(text) and is_list(opts) do
    SessionRouter.submit_async(source, text, opts)
  end
end
