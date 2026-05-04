defmodule Muse.Prompt.Redactor do
  @moduledoc """
  Redacts secrets and sensitive data from prompt preview text.

  Extends `Muse.EventPayloadRedactor` and `Muse.MetadataSanitizer` with
  additional patterns for prompt-specific secret categories:

    * `.env` assignments (`DATABASE_URL=postgres://...`)
    * Private key blocks (`-----BEGIN RSA PRIVATE KEY-----`)
    * JWT / opaque tokens (`eyJ...`)
    * Authorization / API key headers (`X-Api-Key: ...`)
    * Embedded URL credentials (`https://user:pass@host/path`)
    * Codex auth-ish values (`~/.codex/auth.json` references, token-like values)

  ## Public API

    * `redact_text/1`  — redact a string, replacing secret patterns
    * `redact_term/1`  — recursively redact any term (maps, lists, strings)
    * `preview_text/2` — redact + truncate for safe display

  ## Design

  Redaction is applied at the prompt preview boundary — before content
  enters `DebugPreview` or any user-facing output. The assembled prompt
  layers retain their original content for LLM consumption; only previews
  are redacted.
  """

  @redacted "[REDACTED]"

  # URL credential pattern with 3 captures — applied separately from simple patterns
  @url_credential_pattern Regex.compile!("(https?://)([^:@\\s]+):([^@\\s]+)@", [:caseless])

  # Patterns without captures — can use simple replacement string
  @simple_secret_patterns [
    ~r/\b(?:DATABASE_URL|SECRET_KEY|API_KEY|API_SECRET|ACCESS_KEY|SECRET_TOKEN|PRIVATE_KEY|AUTH_TOKEN|BEARER_TOKEN|REFRESH_TOKEN|ENCRYPTION_KEY|SIGNING_KEY|PASSWORD|PASSWD)\s*=\s*\S+/i,
    ~r/-----BEGIN\s+(?:RSA\s+)?(?:PRIVATE\s+KEY|CERTIFICATE)-----[\s\S]*?-----END\s+(?:RSA\s+)?(?:PRIVATE\s+KEY|CERTIFICATE)-----/,
    ~r/\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,
    ~r/\b(?:X-Api-Key|X-Auth-Token|X-Access-Token|X-Session-Token|X-Authorization)\s*:\s*\S+/i,
    ~r/\b(?:codex_auth_token|auth\.json.*?token)\s*[:=]\s*\S+/i,
    ~r/\b(?:token|key|secret|credential|auth)\s*[:=]\s*[A-Za-z0-9+\/=_-]{32,}/i
  ]

  @doc """
  Redact a string by replacing all secret patterns.

  Applies both the existing `EventPayloadRedactor.redact_string/1` patterns
  and the prompt-specific patterns defined in this module.

  ## Examples

      iex> Muse.Prompt.Redactor.redact_text("DATABASE_URL=postgres://user:pass@host/db")
      "DATABASE_URL=[REDACTED]"

      iex> Muse.Prompt.Redactor.redact_text("my key is sk-test-12345")
      "my key is [REDACTED]"
  """
  @spec redact_text(String.t()) :: String.t()
  def redact_text(binary) when is_binary(binary) do
    binary
    |> Muse.EventPayloadRedactor.redact_string()
    |> apply_prompt_patterns()
  end

  @doc """
  Recursively redact any term, replacing secrets in strings and
  sensitive-key values in maps.

  Delegates to `EventPayloadRedactor.redact/1` first, then applies
  prompt-specific patterns to any remaining strings.
  """
  @spec redact_term(term()) :: term()
  def redact_term(term) do
    term
    |> Muse.EventPayloadRedactor.redact()
    |> apply_prompt_patterns_to_term()
  end

  @doc """
  Redact and truncate a string for safe preview display.

  Options:

    * `:max_length` — maximum character length (default 500)

  ## Examples

      iex> Muse.Prompt.Redactor.preview_text("DATABASE_URL=postgres://user:pass@host/db", max_length: 20)
      "DATABASE_URL=[REDACTED]"
  """
  @spec preview_text(String.t(), keyword()) :: String.t()
  def preview_text(binary, opts \\ []) when is_binary(binary) do
    max_length = Keyword.get(opts, :max_length, 500)

    binary
    |> redact_text()
    |> truncate(max_length)
  end

  # -- Private ------------------------------------------------------------------

  defp apply_prompt_patterns(binary) when is_binary(binary) do
    binary
    |> redact_url_credentials()
    |> then(
      &Enum.reduce(@simple_secret_patterns, &1, fn pattern, acc ->
        Regex.replace(pattern, acc, @redacted)
      end)
    )
  end

  defp redact_url_credentials(binary) do
    Regex.replace(@url_credential_pattern, binary, fn _full, scheme, _user, _pass ->
      "#{scheme}#{@redacted}:#{@redacted}@"
    end)
  end

  # Walk terms to apply prompt patterns to any strings found after EventPayloadRedactor
  defp apply_prompt_patterns_to_term(binary) when is_binary(binary) do
    apply_prompt_patterns(binary)
  end

  defp apply_prompt_patterns_to_term(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, apply_prompt_patterns_to_term(v)} end)
  end

  defp apply_prompt_patterns_to_term(%{__struct__: struct_name} = struct) do
    # Traverse struct fields to apply prompt-specific patterns to string values.
    # This ensures prompt-specific secret patterns (e.g. DATABASE_URL=...) in
    # struct/exception message fields are redacted, even though EventPayloadRedactor
    # already handled its own patterns.
    sanitized_map =
      struct
      |> Map.from_struct()
      |> Map.new(fn {k, v} -> {k, apply_prompt_patterns_to_term(v)} end)

    try do
      struct(struct_name, sanitized_map)
    rescue
      # Some structs have enforced keys or validation; if reconstruction fails,
      # return a sanitized map instead of the struct to avoid leaking secrets.
      _ -> sanitized_map
    end
  end

  defp apply_prompt_patterns_to_term(list) when is_list(list) do
    Enum.map(list, &apply_prompt_patterns_to_term/1)
  end

  defp apply_prompt_patterns_to_term(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&apply_prompt_patterns_to_term/1)
    |> List.to_tuple()
  end

  defp apply_prompt_patterns_to_term(term), do: term

  defp truncate(binary, max_length) when is_binary(binary) do
    if String.length(binary) > max_length do
      String.slice(binary, 0, max_length) <> "…"
    else
      binary
    end
  end
end
