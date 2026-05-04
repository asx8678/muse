defmodule Muse.Auth.Credential do
  @moduledoc """
  A resolved authentication credential for an LLM provider.

  The `value` field contains the secret — handle with extreme care.
  Never emit the `value` field into logs, events, or debug output.
  Use the `redacted` field for any safe representation.

  ## Security rules

    * `inspect/1` and all status/diagnostic output must show `redacted`, not `value`.
    * `value` is never emitted into `Muse.Event`, prompt previews, or log output.
    * Errors reference source labels/env var names but never include values.
  """

  @type auth_type :: :api_key | :bearer | :oauth_token
  @type source ::
          :env | :app_config | :provider_config | :codex_cache | :command | :oauth | :prompt
  @type warning :: {:permissive_permissions, String.t()}

  @enforce_keys [:type, :value, :source]
  defstruct [
    :type,
    :value,
    :source,
    :source_ref,
    :expires_at,
    :redacted,
    warnings: []
  ]

  @type t :: %__MODULE__{
          type: auth_type(),
          value: String.t(),
          source: source(),
          source_ref: String.t() | nil,
          expires_at: DateTime.t() | nil,
          redacted: String.t(),
          warnings: [warning()]
        }

  @doc """
  Build a redacted display string from a raw secret value.

  Shows the first 3 characters (if long enough) followed by `...REDACTED`.
  Short or empty values become `***REDACTED***` to avoid leaking length info.
  """
  @spec redact_value(String.t()) :: String.t()
  def redact_value(value) when is_binary(value) do
    prefix_len = 3

    if String.length(value) > prefix_len do
      String.slice(value, 0, prefix_len) <> "...REDACTED"
    else
      "***REDACTED***"
    end
  end

  @doc """
  Return a safe map representation for logging/diagnostics.

  The `value` field is omitted entirely; only `redacted` is included.
  """
  @spec safe_map(t()) :: map()
  def safe_map(%__MODULE__{} = cred) do
    %{
      type: cred.type,
      source: cred.source,
      source_ref: cred.source_ref,
      redacted: cred.redacted,
      expires_at: cred.expires_at,
      warnings: cred.warnings
    }
  end
end

defimpl Inspect, for: Muse.Auth.Credential do
  import Inspect.Algebra

  def inspect(cred, opts) do
    safe = Muse.Auth.Credential.safe_map(cred)
    concat(["#Muse.Auth.Credential<", to_doc(safe, opts), ">"])
  end
end
