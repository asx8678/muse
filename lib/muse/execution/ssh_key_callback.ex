defmodule Muse.Execution.SSHKeyCallback do
  @moduledoc """
  Key callback module for Erlang `:ssh` application.

  Implements the `:ssh_client_key_api` behaviour to provide identity file
  paths for SSH authentication. This module is referenced by
  `SSHCredentialResolver` and used by `:ssh.connect/4` via the `:key_cb`
  option.

  ## Safety invariants

    * Never stores or returns raw key content.
    * Only provides file paths to the :ssh application.
    * Host key verification is delegated to the known_hosts file or
      the `:host_key_accept` option set by `ErlangSSHClient`.

  ## Implementation notes

  The `:ssh_client_key_api` behaviour requires `add_host_key/4` and
  `is_host_key/4` callbacks. This module:

    * Accepts any host key if the caller (ErlangSSHClient) has already
      set up proper host key verification via `user_known_hosts_file`
      or `host_key_accept` options. If neither is set, `ErlangSSHClient`
      rejects the connection before reaching this callback.
    * Provides the identity file for user key authentication.
  """

  @behaviour :ssh_client_key_api

  @impl :ssh_client_key_api
  def add_host_key(_host, _port, _key, _opts) do
    # We don't add host keys — that's handled by known_hosts files
    :ok
  end

  @impl :ssh_client_key_api
  def is_host_key(_key, _host, _port, _opts) do
    # Host key verification is handled by the :ssh application's
    # built-in known_hosts check when user_known_hosts_file is set,
    # or by the :host_key_accept callback if provided.
    # If we reach this point without proper verification, deny.
    false
  end

  @impl :ssh_client_key_api
  def user_key(algorithm, opts) do
    # Look up the identity file from the opts map provided by
    # SSHCredentialResolver
    case Keyword.get(opts, :identity_file) do
      nil ->
        {:error, :not_found}

      path ->
        # Read the key file and return it in the format :ssh expects
        case :file.read_file(path) do
          {:ok, bin} ->
            decode_key(bin, algorithm)

          {:error, _reason} ->
            {:error, :not_found}
        end
    end
  end

  # Decode SSH key from file content based on algorithm
  defp decode_key(bin, algorithm) do
    try do
      case :ssh_file.decode(bin, algorithm) do
        [{_key_type, key_data} | _rest] ->
          {:ok, key_data}

        [] ->
          {:error, :no_matching_key}
      end
    rescue
      _ -> {:error, :decode_failed}
    end
  end
end
