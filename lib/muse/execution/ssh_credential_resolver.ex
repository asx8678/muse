defmodule Muse.Execution.SSHCredentialResolver do
  @moduledoc """
  Safe SSH credential resolver for the SSH execution pipeline.

  Resolves opaque credential references into Erlang `:ssh` connection
  options (identity file paths, key algorithms) without ever storing
  or exposing raw key material, passwords, or passphrases.

  ## Credential model

  Supports the following credential reference types:

    * `%{type: "identity_file", path: "/path/to/key"}` — references an
      SSH private key file on disk. The path is resolved and validated
      but never included in events, logs, or results.

    * `{:identity_file, path}` — tuple form of the above.

  ## Safety invariants

    * Never returns raw key contents — only a private key callback configured
      with an identity-file path for Erlang `:ssh` to read at connect time.
    * Never stores credentials — resolves on demand and returns only
      the options needed by `:ssh.connect/4`.
    * Errors are redacted — never leak key paths or credential details.
    * Passphrases and raw key data are rejected as credential refs.
    * Only identity-file references are supported initially.

  ## Non-goals

    * No password-based authentication support (security risk).
    * No agent forwarding (security risk).
    * No raw key content in credential refs (must use file paths).
    * No passphrase storage (passphrase-protected keys must be unlocked
      via ssh-agent, which is outside this module's scope).
  """

  @type credential_ref :: term()

  @doc """
  Resolve a credential reference into Erlang `:ssh` connection options.

  Returns `{:ok, ssh_opts}` where `ssh_opts` is a keyword list suitable
  for passing to `:ssh.connect/4`, or `{:error, redacted_reason}` if
  the credential reference is invalid or unsupported.

  ## Examples

      iex> Muse.Execution.SSHCredentialResolver.resolve(%{type: "identity_file", path: "/home/user/.ssh/id_ed25519"})
      {:ok, [{:key_cb, {Muse.Execution.SSHKeyCallback, [identity_file: ~c"/home/user/.ssh/id_ed25519"]}}]}

      iex> Muse.Execution.SSHCredentialResolver.resolve(%{type: "password", value: "secret"})
      {:error, "unsupported credential type: password"}
  """
  @spec resolve(credential_ref()) :: {:ok, keyword()} | {:error, String.t()}
  def resolve(%{type: "identity_file", path: path}) when is_binary(path) do
    resolve_identity_file(path)
  end

  def resolve({:identity_file, path}) when is_binary(path) do
    resolve_identity_file(path)
  end

  # Reject password-based credential refs
  def resolve(%{type: "password"}), do: {:error, "unsupported credential type: password"}

  # Reject raw key content
  def resolve(%{type: "private_key"}), do: {:error, "unsupported credential type: private_key"}

  # Reject passphrase
  def resolve(%{type: "passphrase"}), do: {:error, "unsupported credential type: passphrase"}

  # Reject other unsupported types
  def resolve(%{type: type}) when is_binary(type) do
    # Do not echo arbitrary credential type strings; callers can provide
    # secret-bearing data in unsupported fields.
    {:error, "unsupported credential type"}
  end

  # Reject nil
  def resolve(nil), do: {:error, "credential reference is required"}

  # Reject anything else
  def resolve(_other) do
    {:error, "unsupported credential reference format"}
  end

  # -- Private helpers -----------------------------------------------------------

  defp resolve_identity_file(path) do
    cond do
      # Path must be non-empty
      path == "" ->
        {:error, "identity file path must not be empty"}

      # Path must not contain control characters
      String.match?(path, ~r/[[:cntrl:]]/) ->
        {:error, "identity file path contains control characters"}

      # Path must not contain path traversal
      String.contains?(path, "..") ->
        {:error, "identity file path must not contain path traversal"}

      true ->
        # Return Erlang :ssh key_cb options pointing to the identity file.
        # The actual key is never loaded into memory by this module —
        # the :ssh application reads it at connect time.
        charlist_path = String.to_charlist(path)

        {:ok,
         [
           {:key_cb, {Muse.Execution.SSHKeyCallback, [identity_file: charlist_path]}}
         ]}
    end
  end
end
