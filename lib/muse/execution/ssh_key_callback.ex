defmodule Muse.Execution.SSHKeyCallback do
  @moduledoc """
  Key callback module for Erlang `:ssh` application.

  Implements the `:ssh_client_key_api` behaviour to provide identity file
  paths for SSH authentication. This module is referenced by
  `SSHCredentialResolver` and used by `:ssh.connect/4` via the `:key_cb`
  option.

  ## Safety invariants

    * Never stores or emits raw key content.
    * Reads only the configured identity file when Erlang `:ssh` requests a
      user key for authentication.
    * Verifies host keys against a configured known_hosts file or pinned
      fingerprint. It never silently accepts unknown hosts or prompts users.

  ## Implementation notes

  The `:ssh_client_key_api` behaviour requires host-key and user-key callbacks.
  This module:

    * Returns `false` for unknown host keys, causing the SSH connection to fail
      closed rather than falling back to TOFU or an interactive prompt.
    * Does not persist host keys (`add_host_key/4` returns an error).
    * Provides the configured identity file for user key authentication without
      exposing key contents in errors or logs.
  """

  @behaviour :ssh_client_key_api

  @impl :ssh_client_key_api
  def add_host_key(_host, _port, _key, _opts) do
    # Do not implement TOFU/persistence. Hosts must already be trusted via the
    # configured known_hosts file or a pinned fingerprint.
    {:error, :host_key_persistence_disabled}
  end

  @impl :ssh_client_key_api
  def is_host_key(key, hosts, port, _algorithm, opts) do
    pinned_fingerprint_matches?(key, opts) or known_hosts_trusts_key?(key, hosts, port, opts)
  rescue
    _ -> false
  end

  @impl :ssh_client_key_api
  def is_host_key(key, host, algorithm, opts) do
    # Compatibility fallback for older OTP callback shape. Without a port in the
    # callback, only the default SSH port can be checked safely.
    is_host_key(key, host, 22, algorithm, opts)
  end

  @impl :ssh_client_key_api
  def user_key(algorithm, opts) do
    case private_opt(opts, :identity_file) do
      nil ->
        {:error, ~c"identity key unavailable"}

      path ->
        read_identity_file(path, algorithm)
    end
  rescue
    _ -> {:error, ~c"identity key unavailable"}
  end

  defp read_identity_file(path, algorithm) do
    with {:ok, bin} <- :file.read_file(path),
         {:ok, [{key_data, _attrs} | _rest]} <- decode_identity_key(bin, algorithm) do
      {:ok, key_data}
    else
      _ -> {:error, ~c"identity key unavailable"}
    end
  end

  defp decode_identity_key(bin, algorithm) do
    :ssh_file.decode_ssh_file(:private, algorithm, bin, :ignore)
  rescue
    _ -> {:error, :decode_failed}
  end

  defp known_hosts_trusts_key?(key, hosts, port, opts) do
    case private_opt(opts, :known_hosts_file) do
      nil ->
        false

      path ->
        candidates = host_candidates(hosts, port)

        with {:ok, bin} <- :file.read_file(path),
             decoded when is_list(decoded) <- :ssh_file.decode(bin, :known_hosts) do
          Enum.any?(decoded, &known_host_entry_matches?(&1, key, candidates))
        else
          _ -> false
        end
    end
  end

  defp known_host_entry_matches?({known_key, attrs}, key, candidates) do
    known_key == key and
      attrs
      |> Keyword.get(:hostnames, [])
      |> Enum.any?(&known_host_pattern_matches?(&1, candidates))
  end

  defp known_host_entry_matches?(_entry, _key, _candidates), do: false

  defp known_host_pattern_matches?(pattern, candidates) do
    pattern = to_string(pattern)
    pattern == "*" or pattern in candidates
  end

  defp host_candidates(hosts, port) do
    hosts
    |> List.wrap()
    |> Enum.flat_map(&host_strings(&1, port))
    |> Enum.uniq()
  end

  defp host_strings(host, port) do
    host_string = host_to_string(host)

    cond do
      host_string == "" -> []
      port == 22 -> [host_string, "[#{host_string}]:22"]
      true -> ["[#{host_string}]:#{port}", "#{host_string}:#{port}", host_string]
    end
  end

  defp host_to_string(tuple) when is_tuple(tuple) do
    tuple
    |> :inet.ntoa()
    |> to_string()
  rescue
    _ -> ""
  end

  defp host_to_string(host), do: to_string(host)

  defp pinned_fingerprint_matches?(key, opts) do
    case private_opt(opts, :pinned_fingerprint) do
      nil ->
        false

      fingerprint ->
        expected = normalize_fingerprint(fingerprint)

        key
        |> possible_fingerprints()
        |> Enum.any?(&(normalize_fingerprint(&1) == expected))
    end
  end

  defp possible_fingerprints(key) do
    [
      safe_fingerprint(fn -> :ssh.hostkey_fingerprint(key) end),
      safe_fingerprint(fn -> :ssh.hostkey_fingerprint(:sha256, key) end),
      safe_fingerprint(fn -> :ssh.hostkey_fingerprint(:sha, key) end),
      safe_fingerprint(fn -> :ssh.hostkey_fingerprint(:md5, key) end)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp safe_fingerprint(fun) do
    fun.() |> IO.iodata_to_binary()
  rescue
    _ -> nil
  end

  defp normalize_fingerprint(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "")
  end

  defp private_opt(opts, key) when is_list(opts) do
    case Keyword.get(opts, key) do
      nil ->
        opts
        |> Keyword.get(:key_cb_private, [])
        |> Keyword.get(key)

      value ->
        value
    end
  end

  defp private_opt(_opts, _key), do: nil
end
