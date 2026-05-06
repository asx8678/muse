defmodule Muse.EventPayloadRedactor do
  @moduledoc """
  Redacts secret patterns from event payloads before they enter `%Muse.Event{}`.

  Works recursively through maps, lists, and strings. Applies two layers of
  redaction:

    1. **Sensitive key redaction** — values under keys matching
       `Muse.MetadataSanitizer.sensitive_key?/1` are replaced with
       `"[REDACTED]"`.

    2. **Secret string pattern redaction** — strings containing obvious
       credential patterns (API keys, Bearer tokens, etc.) have the
       secret portion replaced with `"[REDACTED]"`.

  ## Supported secret patterns

    * `sk-...`, `key-...` (API key prefixes)
    * `Bearer ...` / `Authorization: Bearer ...`
    * `Authorization: ...` and common API-key/token headers
    * OAuth/Codex-looking tokens (`oauth_token=...`, `ya29....`, `gho_...`)
    * `api_key=...` / `api-key: ...` / `token=...` / `secret=...`

  ## Usage

      iex> Muse.EventPayloadRedactor.redact(%{text: "my key is sk-test-12345"})
      %{text: "my key is [REDACTED]"}

      iex> Muse.EventPayloadRedactor.redact(%{api_key: "shhh", note: "safe"})
      %{api_key: "[REDACTED]", note: "safe"}
  """

  @redacted "[REDACTED]"

  # Regex patterns for secret strings. Each match is replaced wholesale with
  # the redaction marker. Keep authorization/header patterns before generic
  # Bearer matching so whole header-like fragments are removed together.
  @secret_patterns [
    # Authorization header: Authorization: Bearer abc123
    ~r/\bAuthorization\s*:\s*Bearer\s+[^\s"'`,;]+/i,
    # Other authorization header/assignment forms: Authorization: Basic abc
    ~r/\bAuthorization\s*[:=]\s*(?:[A-Za-z]+\s+)?[^\s"'`,;]+/i,
    # Common API-key/token headers: X-Api-Key: abc123
    ~r/\b(?:X-Api-Key|X-Auth-Token|X-Access-Token|X-Session-Token|X-Authorization)\s*:\s*[^\s"'`,;]+/i,
    # Bearer tokens: Bearer abc123
    ~r/\bBearer\s+[^\s"'`,;]+/i,
    # JWT/OIDC tokens and common OAuth/PAT prefixes.
    ~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,
    ~r/\bya29\.[A-Za-z0-9._-]+/,
    ~r/\bgh[opsu]_[A-Za-z0-9_]{20,}/,
    ~r/\bxox[baprs]-[A-Za-z0-9-]+/,
    # API key prefixes: sk-test-12345, sk-proj-abc, key-live-abc123
    ~r/\b(?:sk|pk|key)-[A-Za-z0-9_-]{6,}/,
    # Query-string/assignment secrets: api_key=..., oauth_token=..., token=...
    ~r/\b(?:api[_-]?key|oauth(?:2)?[_-]?(?:access[_-]?)?token|codex(?:[_-]?auth)?[_-]?token|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|token|secret|password)\s*=\s*["']?[^\s"'&,;)]+/i,
    ~r/\b(?:api[_-]?key|oauth(?:2)?[_-]?(?:access[_-]?)?token|codex(?:[_-]?auth)?[_-]?token|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|token|secret|password)\s*:\s*["']?[^\s"',;)]+/i
  ]

  @doc """
  Recursively redact a term, returning a safe copy suitable for event data.

  Preserves structural types (maps, lists) while replacing sensitive values.
  """
  @spec redact(term()) :: term()
  def redact(term), do: redact(term, nil)

  # -- redact/2 clauses (grouped together) ---------------------------------------

  # Map: walk each key/value pair, redact sensitive-key values, recurse others
  defp redact(map, _parent_key) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      if Muse.MetadataSanitizer.sensitive_key?(k) do
        {k, @redacted}
      else
        {k, redact(v, k)}
      end
    end)
  end

  # Struct: convert to map, redact, but preserve struct identity
  defp redact(%{__struct__: struct_name} = struct, _parent_key) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {k, v} ->
      if Muse.MetadataSanitizer.sensitive_key?(k) do
        {k, @redacted}
      else
        {k, redact(v, k)}
      end
    end)
    |> then(fn map -> struct(struct_name, map) end)
  end

  # List: check if it's a keyword list (list of 2-tuples with atom/string keys)
  # Otherwise, redact each element normally.
  defp redact(list, parent_key) when is_list(list) do
    if keyword_list?(list) do
      # Treat as key-value pairs: check sensitive keys
      Enum.map(list, fn {k, v} ->
        if Muse.MetadataSanitizer.sensitive_key?(k) do
          {k, @redacted}
        else
          {k, redact(v, k)}
        end
      end)
    else
      Enum.map(list, &redact(&1, parent_key))
    end
  end

  # Tuple: check if it's a 2-element key-value pair
  defp redact({key, value}, _parent_key) when is_tuple(key) == false do
    # Single key-value pair tuple: check if key is sensitive
    if Muse.MetadataSanitizer.sensitive_key?(key) do
      {key, @redacted}
    else
      {key, redact(value, key)}
    end
  end

  # Tuple with more than 2 elements: convert to list, redact, convert back
  defp redact(tuple, parent_key) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&redact(&1, parent_key))
    |> List.to_tuple()
  end

  # String: apply secret pattern redaction
  defp redact(binary, _parent_key) when is_binary(binary) do
    Enum.reduce(@secret_patterns, binary, fn pattern, acc ->
      Regex.replace(pattern, acc, fn _full -> @redacted end)
    end)
  end

  # Primitives and other terms: pass through unchanged
  defp redact(term, _parent_key), do: term

  # -- Helper functions ----------------------------------------------------------

  # Helper: check if list is a keyword list (list of 2-tuples with atom keys)
  # or a list of string-key tuples
  defp keyword_list?([]), do: true
  defp keyword_list?([{k, _v} | rest]) when is_atom(k), do: keyword_list?(rest)
  defp keyword_list?([{k, _v} | rest]) when is_binary(k), do: keyword_list?(rest)
  defp keyword_list?(_), do: false

  # -- Public API ---------------------------------------------------------------

  @doc """
  Redact a string by replacing secret patterns.

  Useful for one-off string redaction without recursive map walking.

      iex> Muse.EventPayloadRedactor.redact_string("key=sk-test-12345")
      "key=[REDACTED]"
  """
  @spec redact_string(String.t()) :: String.t()
  def redact_string(binary) when is_binary(binary) do
    Enum.reduce(@secret_patterns, binary, fn pattern, acc ->
      Regex.replace(pattern, acc, fn _full -> @redacted end)
    end)
  end
end
