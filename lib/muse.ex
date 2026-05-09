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
end
