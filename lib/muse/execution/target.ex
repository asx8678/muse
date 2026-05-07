defmodule Muse.Execution.Target do
  @moduledoc """
  Describes a remote execution target.

  Targets are stored in the Target Registry and referenced by
  `target_id` in approval records and audit events.

  ## Safety properties

    * `protocol` must be one of the known protocols (`:fake`, `:ssh`).
      Unknown protocols are rejected at construction.
    * No `String.to_atom/1` — protocol is validated against a fixed map.
    * Safe event payload excludes `user`, `credential_ref`, `connection_opts`,
      and any other sensitive fields. Uses an explicit allowlist.
    * `:ssh` protocol is a known future protocol but remains denied
      (no SSHRunner module exists in Phase C).

  ## Fields

    * `id` — unique target identifier (string)
    * `label` — human-readable label
    * `protocol` — `:fake` or `:ssh` (ssh denied for now)
    * `host` — hostname or IP address (required, non-empty, non-nil)
    * `port` — port number
    * `user` — remote user (NEVER in user-visibility events)
    * `connection_opts` — connection options (NEVER in events)
    * `credential_ref` — opaque reference to CredentialStore (NEVER in events)
    * `tags` — list of string tags
    * `created_at` — creation timestamp
    * `updated_at` — last update timestamp

  """

  @enforce_keys [:id, :protocol, :host]
  defstruct [
    :id,
    :label,
    :protocol,
    :host,
    :port,
    :user,
    :connection_opts,
    :credential_ref,
    tags: [],
    metadata: %{},
    created_at: nil,
    updated_at: nil
  ]

  @type protocol :: :fake | :ssh

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t() | nil,
          protocol: protocol(),
          host: String.t(),
          port: non_neg_integer() | nil,
          user: String.t() | nil,
          connection_opts: keyword() | nil,
          credential_ref: term() | nil,
          tags: [String.t()],
          metadata: map(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # Known protocols — no dynamic atom creation from user input
  @known_protocols %{
    "fake" => :fake,
    "ssh" => :ssh
  }

  # Allowlist for safe event payloads — never includes user, credential_ref,
  # connection_opts, or any other sensitive fields
  @safe_payload_keys [:id, :label, :protocol, :host, :port, :tags]

  @doc """
  Create a new Target with validation.

  ## Options

    * `:label` — human-readable label
    * `:protocol` — `:fake` or `:ssh` (default: `:fake`)
    * `:host` — hostname or IP (required, non-empty, non-nil)
    * `:port` — port number
    * `:user` — remote user (never included in safe payloads)
    * `:connection_opts` — connection options (never included in safe payloads)
    * `:credential_ref` — opaque credential reference (never included in safe payloads)
    * `:tags` — list of string tags
    * `:metadata` — additional metadata map
    * `:created_at` — creation timestamp (default: `DateTime.utc_now/0`)
    * `:updated_at` — update timestamp (default: same as `created_at`)

  ## Examples

      iex> {:ok, target} = Muse.Execution.Target.new("tgt_staging", protocol: :fake, host: "staging.example.com")
      iex> target.id
      "tgt_staging"

      iex> {:error, reason} = Muse.Execution.Target.new("tgt_bad", protocol: :unknown, host: "bad.host")
      iex> reason
      "protocol must be one of: fake, ssh"

  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(id, opts \\ [])

  def new(id, opts) when is_binary(id) and is_list(opts) do
    with :ok <- validate_id(id),
         {:ok, protocol} <- parse_protocol(Keyword.get(opts, :protocol, :fake)),
         :ok <- validate_host(Keyword.get(opts, :host)),
         :ok <- validate_label(Keyword.get(opts, :label)),
         :ok <- validate_tags(Keyword.get(opts, :tags, [])) do
      now = DateTime.utc_now()
      created_at = Keyword.get(opts, :created_at, now)
      updated_at = Keyword.get(opts, :updated_at, created_at)

      target = %__MODULE__{
        id: id,
        label: Keyword.get(opts, :label),
        protocol: protocol,
        host: Keyword.get(opts, :host),
        port: Keyword.get(opts, :port),
        user: Keyword.get(opts, :user),
        connection_opts: Keyword.get(opts, :connection_opts),
        credential_ref: Keyword.get(opts, :credential_ref),
        tags: Keyword.get(opts, :tags, []),
        metadata: Keyword.get(opts, :metadata, %{}),
        created_at: created_at,
        updated_at: updated_at
      }

      {:ok, target}
    end
  end

  def new(id, _opts) when not is_binary(id) do
    {:error, "id must be a non-empty string"}
  end

  @doc """
  Create a new Target or raise on validation error.
  """
  @spec new!(String.t(), keyword()) :: t()
  def new!(id, opts \\ []) do
    case new(id, opts) do
      {:ok, target} -> target
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Parse a protocol value safely without `String.to_atom/1`.

  Accepts atoms (`:fake`, `:ssh`) or strings (`"fake"`, `"ssh"`).
  Returns `{:ok, atom}` for known protocols, `{:error, reason}` otherwise.

  ## Examples

      iex> Muse.Execution.Target.parse_protocol(:fake)
      {:ok, :fake}

      iex> Muse.Execution.Target.parse_protocol("ssh")
      {:ok, :ssh}

      iex> Muse.Execution.Target.parse_protocol("unknown")
      {:error, "protocol must be one of: fake, ssh"}

      iex> Muse.Execution.Target.parse_protocol(:unknown)
      {:error, "protocol must be one of: fake, ssh"}
  """
  @spec parse_protocol(atom() | String.t()) :: {:ok, protocol()} | {:error, String.t()}
  def parse_protocol(protocol) when protocol in [:fake, :ssh], do: {:ok, protocol}

  def parse_protocol(protocol) when is_binary(protocol) do
    case Map.get(@known_protocols, String.downcase(String.trim(protocol))) do
      nil -> {:error, "protocol must be one of: fake, ssh"}
      atom -> {:ok, atom}
    end
  end

  def parse_protocol(_), do: {:error, "protocol must be one of: fake, ssh"}

  # Substring bare-credential pattern for id, label, tags, host fields.
  # Matches username:password@hostname where password may contain @ and :.
  # Greedy \S+ backtracks to find the LAST @ before a valid hostname segment.
  # Lookahead ensures the hostname ends at a word boundary.
  @bare_credential_substring_pattern ~r/([^\s@:]+):(\S+)@([\w][\w.\-]*)(?=[^\w.\-]|$)/

  @doc """
  Return a safe event payload for the target.

  Uses an explicit allowlist of safe keys. Never includes `user`,
  `credential_ref`, `connection_opts`, or any other sensitive fields.
  Applies `Muse.Prompt.Redactor.redact_term/1` to redact secret-like
  patterns in field values (host, id, label, tags) so payloads are
  safe by construction even if those fields contain credential-bearing
  or secret-like values.

  Additionally sanitizes the `:host` field for bare `user:pass@host`
  patterns that may appear in manually constructed targets (structs
  created without `new/2` validation).

  ## Examples

      iex> {:ok, target} = Muse.Execution.Target.new("tgt_1", protocol: :fake, host: "host.io", user: "deploy")
      iex> payload = Muse.Execution.Target.safe_payload(target)
      iex> Map.has_key?(payload, :user)
      false
      iex> Map.has_key?(payload, :id)
      true
  """
  @spec safe_payload(t()) :: map()
  def safe_payload(%__MODULE__{} = target) do
    target
    |> Map.from_struct()
    |> Map.take(@safe_payload_keys)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
    |> redact_bare_credentials_in_payload()
    |> Muse.Prompt.Redactor.redact_term()
  end

  # Recursively redact bare user:pass@host patterns in all string fields.
  # This handles both the host field (entire value may be credentials) and
  # substrings in id, label, and tags. URL :// patterns are handled later
  # by Muse.Prompt.Redactor.redact_term/1.
  defp redact_bare_credentials_in_payload(payload) do
    payload
    |> maybe_redact_string_field(:id)
    |> maybe_redact_string_field(:label)
    |> maybe_redact_string_field(:host)
    |> maybe_redact_tags_field()
  end

  defp maybe_redact_string_field(payload, key) when key in [:id, :label, :host] do
    case Map.get(payload, key) do
      value when is_binary(value) ->
        Map.put(payload, key, redact_bare_credentials_in_string(value))

      _ ->
        payload
    end
  end

  defp maybe_redact_tags_field(payload) do
    case Map.get(payload, :tags) do
      tags when is_list(tags) ->
        Map.put(payload, :tags, Enum.map(tags, &redact_bare_credentials_in_string/1))

      _ ->
        payload
    end
  end

  defp redact_bare_credentials_in_string(string) when is_binary(string) do
    Regex.replace(
      @bare_credential_substring_pattern,
      string,
      fn _full, _user, _pass, hostname ->
        "[REDACTED]@" <> hostname
      end
    )
  end

  @doc """
  Return the list of known protocols.
  """
  @spec known_protocols() :: [protocol()]
  def known_protocols, do: Map.values(@known_protocols)

  # -- Validation helpers -------------------------------------------------------

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0 do
    cond do
      String.contains?(id, "\0") ->
        {:error, "id contains NUL character"}

      String.match?(id, ~r/[[:cntrl:]]/) ->
        {:error, "id contains control characters"}

      true ->
        :ok
    end
  end

  defp validate_id(_), do: {:error, "id must be a non-empty string"}

  defp validate_host(nil), do: {:error, "host must not be nil"}
  defp validate_host(""), do: {:error, "host must not be empty"}

  defp validate_host(host) when is_binary(host) do
    cond do
      String.contains?(host, "\0") ->
        {:error, "host contains NUL character"}

      String.match?(host, ~r/[[:cntrl:]]/) ->
        {:error, "host contains control characters"}

      credential_bearing_host?(host) ->
        {:error, "host must not contain credentials (user:pass@ or ://...@ patterns)"}

      true ->
        :ok
    end
  end

  defp validate_host(_), do: {:error, "host must be a non-empty string"}

  defp credential_bearing_host?(host) do
    # Reject hosts with URL userinfo patterns: ://...@ (RFC 3986 userinfo)
    # or bare user:pass@host forms
    (String.contains?(host, "://") and String.contains?(host, "@")) or
      String.match?(host, ~r/^[^@:]+:[^@]+@/)
  end

  defp validate_tags(tags) when is_list(tags) do
    cond do
      not Enum.all?(tags, &is_binary/1) ->
        {:error, "tags must be a list of strings"}

      Enum.any?(tags, &String.contains?(&1, "\0")) ->
        {:error, "tags contain NUL character"}

      Enum.any?(tags, &String.match?(&1, ~r/[[:cntrl:]]/)) ->
        {:error, "tags contain control characters"}

      true ->
        :ok
    end
  end

  defp validate_tags(_), do: {:error, "tags must be a list of strings"}

  defp validate_label(nil), do: :ok

  defp validate_label(label) when is_binary(label) do
    cond do
      String.contains?(label, "\0") ->
        {:error, "label contains NUL character"}

      String.match?(label, ~r/[[:cntrl:]]/) ->
        {:error, "label contains control characters"}

      true ->
        :ok
    end
  end

  defp validate_label(_), do: {:error, "label must be a string or nil"}
end
