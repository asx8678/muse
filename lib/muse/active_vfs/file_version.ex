defmodule Muse.ActiveVFS.FileVersion do
  @moduledoc """
  A single version of a file tracked by the ActiveVFS.

  Each `FileVersion` records the file path, content snapshot, monotonically
  increasing version number, the agent that created it, a human-readable
  reason string, and a timestamp.

  Version 0 is the "base" version loaded from disk. Subsequent versions are
  created by `commit/4` and `rollback/2`.

  ## Fields

    * `:path` — relative file path within the workspace
    * `:content` — file content at this version
    * `:version_number` — monotonically increasing (0 = base)
    * `:agent_id` — identifier of the agent that created this version
    * `:reason` — human-readable description of the change
    * `:timestamp` — `DateTime.t()` when this version was created

  """

  @type t :: %__MODULE__{
          path: String.t(),
          content: String.t(),
          version_number: non_neg_integer(),
          agent_id: String.t(),
          reason: String.t(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:path, :content, :version_number, :agent_id, :reason, :timestamp]
  defstruct [:path, :content, :version_number, :agent_id, :reason, :timestamp]
end
