defmodule Muse.Execution.ErlangSSHClient do
  @moduledoc """
  SSH client adapter wrapping the Erlang `:ssh` application.

  This is the production adapter for real SSH connections. It:

    * Resolves credentials via `Muse.Execution.SSHCredentialResolver`
    * Enforces host key verification (no silent acceptance)
    * Executes commands via SSH exec channel
    * Collects stdout/stderr/exit_status within timeout
    * Disconnects best-effort without raising

  ## Safety invariants

    * Never stores credentials in the connection ref
    * Never emits credentials in errors or logs
    * Rejects `silently_accept_hosts: true` and `user_interaction: true`
    * Requires explicit known_hosts path or pinned fingerprint
    * Connection ref is an opaque tuple — not externally inspectable

  ## Not for default tests

  This adapter requires a live SSH server. Default `mix test` uses
  `Muse.Execution.FakeSSHClient` instead. Live SSH tests are opt-in
  via tag `:ssh_live`.
  """

  @behaviour Muse.Execution.SSHClient

  alias Muse.Execution.SSHCredentialResolver

  @default_connect_timeout 30_000
  @default_exec_timeout 60_000

  @impl Muse.Execution.SSHClient
  def connect(target, opts \\ []) do
    host = Map.get(target, :host)
    port = Map.get(target, :port, 22)
    user = Map.get(target, :user)
    credential_ref = Map.get(target, :credential_ref)
    connection_opts = Map.get(target, :connection_opts, [])
    timeout = Keyword.get(opts, :timeout_ms, @default_connect_timeout)

    with :ok <- validate_connect_params(host, port, user, credential_ref),
         {:ok, ssh_opts} <-
           build_ssh_opts(host, port, user, credential_ref, connection_opts, timeout) do
      case :ssh.connect(String.to_charlist(host), port, ssh_opts, timeout) do
        {:ok, conn_ref} ->
          ref = make_ref()
          {:ok, {__MODULE__, ref, conn_ref}}

        {:error, reason} ->
          {:error, redact_connect_error(reason)}
      end
    end
  end

  @impl Muse.Execution.SSHClient
  def exec(connection_ref, command_string, opts \\ [])

  def exec({__MODULE__, _ref, conn_ref}, command_string, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_exec_timeout)

    case :ssh_connection.session_channel(conn_ref, timeout) do
      {:ok, channel} ->
        try do
          exec_on_channel(conn_ref, channel, command_string, timeout)
        after
          # Best-effort close the channel
          try do
            :ssh_connection.close(conn_ref, channel)
          rescue
            _ -> :ok
          end
        end

      {:error, reason} ->
        {:error, redact_exec_error(reason)}
    end
  end

  def exec(_invalid_ref, _command_string, _opts) do
    {:error, "invalid or disconnected SSH connection"}
  end

  @impl Muse.Execution.SSHClient
  def disconnect({__MODULE__, _ref, conn_ref}) do
    try do
      :ssh.close(conn_ref)
    rescue
      _ -> :ok
    end

    :ok
  end

  def disconnect(_invalid_ref) do
    :ok
  end

  # -- Private: connection parameter validation ----------------------------------

  defp validate_connect_params(host, port, user, credential_ref) do
    cond do
      not is_binary(host) or host == "" ->
        {:error, "SSH connection requires a valid host"}

      not is_integer(port) or port not in 1..65_535 ->
        {:error, "SSH connection requires a valid port"}

      not is_binary(user) or user == "" ->
        {:error, "SSH connection requires a valid user"}

      credential_ref == nil ->
        {:error, "SSH connection requires a credential reference"}

      true ->
        :ok
    end
  end

  # -- Private: SSH option building --------------------------------------------

  defp build_ssh_opts(_host, _port, user, credential_ref, connection_opts, timeout) do
    with {:ok, cred_opts} <- SSHCredentialResolver.resolve(credential_ref),
         {:ok, host_key_private_opts} <- host_key_verification_opts(connection_opts),
         :ok <- validate_connection_opts_safety(connection_opts) do
      base_opts = [
        {:user, String.to_charlist(user)},
        {:silently_accept_hosts, false},
        {:user_interaction, false},
        {:connect_timeout, timeout},
        {:save_accepted_host, false},
        {:quiet_mode, true}
      ]

      cred_opts = merge_key_cb_private_opts(cred_opts, host_key_private_opts)
      opts = base_opts ++ cred_opts ++ safe_connection_opts(connection_opts)
      {:ok, opts}
    end
  end

  # -- Private: host key verification ------------------------------------------

  defp host_key_verification_opts(connection_opts) do
    known_hosts_path =
      find_opt(connection_opts, :user_known_hosts_file) ||
        find_opt(connection_opts, :known_hosts_file)

    pinned_fingerprint =
      find_opt(connection_opts, :host_key_accept) ||
        find_opt(connection_opts, :host_key_fingerprint)

    cond do
      is_binary(known_hosts_path) ->
        with :ok <- validate_reference_path(known_hosts_path, "known_hosts path") do
          {:ok, [{:known_hosts_file, String.to_charlist(known_hosts_path)}]}
        end

      is_binary(pinned_fingerprint) ->
        with :ok <- validate_fingerprint(pinned_fingerprint) do
          {:ok, [{:pinned_fingerprint, pinned_fingerprint}]}
        end

      is_function(pinned_fingerprint) ->
        {:error, "SSH host key verification callbacks are not supported"}

      true ->
        {:error,
         "SSH host key verification is required; specify :user_known_hosts_file or a pinned :host_key_accept fingerprint in connection_opts"}
    end
  end

  defp merge_key_cb_private_opts(cred_opts, host_key_private_opts) do
    Keyword.update(cred_opts, :key_cb, nil, fn
      {module, key_cb_private_opts} when is_atom(module) and is_list(key_cb_private_opts) ->
        {module, Keyword.merge(key_cb_private_opts, host_key_private_opts)}

      other ->
        other
    end)
  end

  defp validate_reference_path(path, label) do
    cond do
      path == "" ->
        {:error, "SSH #{label} must not be empty"}

      String.match?(path, ~r/[[:cntrl:]]/) ->
        {:error, "SSH #{label} contains control characters"}

      String.contains?(path, "..") ->
        {:error, "SSH #{label} must not contain path traversal"}

      true ->
        :ok
    end
  end

  defp validate_fingerprint(fingerprint) do
    cond do
      String.trim(fingerprint) == "" ->
        {:error, "SSH host key fingerprint must not be empty"}

      String.match?(fingerprint, ~r/[[:cntrl:]]/) ->
        {:error, "SSH host key fingerprint contains control characters"}

      true ->
        :ok
    end
  end

  defp find_opt(opts, key) when is_list(opts) do
    Keyword.get(opts, key)
  end

  defp find_opt(_, _), do: nil

  # -- Private: connection options safety ----------------------------------------

  # Allowlisted connection options that are safe to pass through.
  # Dangerous options are rejected.
  @allowed_ssh_opts [
    :connect_timeout,
    :transport,
    :auth_methods,
    :pref_public_key_algs,
    :preferred_algorithms,
    :modify_algorithms,
    :idle_time
  ]

  # Options that are NEVER allowed (security risks)
  @denied_ssh_opts [
    :silently_accept_hosts,
    :user_interaction,
    :password,
    :private_key,
    :passphrase,
    :dsa_pass_phrase,
    :rsa_pass_phrase,
    :ecdsa_pass_phrase,
    :pk_cs12_password
  ]

  defp validate_connection_opts_safety(connection_opts) when is_list(connection_opts) do
    cond do
      # Check for denied options
      Enum.any?(@denied_ssh_opts, fn key -> Keyword.has_key?(connection_opts, key) end) ->
        denied =
          @denied_ssh_opts
          |> Enum.filter(&Keyword.has_key?(connection_opts, &1))
          |> Enum.join(", ")

        {:error, "dangerous SSH connection options rejected: #{denied}"}

      true ->
        :ok
    end
  end

  defp validate_connection_opts_safety(_), do: :ok

  defp safe_connection_opts(connection_opts) when is_list(connection_opts) do
    connection_opts
    |> Keyword.take(@allowed_ssh_opts)
    |> Enum.map(fn {k, v} ->
      case v do
        s when is_binary(s) -> {k, String.to_charlist(s)}
        other -> {k, other}
      end
    end)
  end

  defp safe_connection_opts(_), do: []

  # -- Private: command execution on channel ------------------------------------

  defp exec_on_channel(conn_ref, channel, command_string, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case :ssh_connection.exec(conn_ref, channel, String.to_charlist(command_string), timeout) do
      :ok ->
        collect_channel_output(conn_ref, channel, deadline, %{
          stdout: "",
          stderr: "",
          exit_status: nil
        })

      {:error, reason} ->
        {:error, redact_exec_error(reason)}
    end
  end

  defp collect_channel_output(conn_ref, channel, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:ok, %{acc | timed_out: true}}
    else
      receive do
        {:ssh_cm, ^conn_ref, {:data, ^channel, 0, data}} ->
          # stdout (type 0)
          collect_channel_output(conn_ref, channel, deadline, %{
            acc
            | stdout: append_capped(acc.stdout, IO.iodata_to_binary(data))
          })

        {:ssh_cm, ^conn_ref, {:data, ^channel, 1, data}} ->
          # stderr (type 1)
          collect_channel_output(conn_ref, channel, deadline, %{
            acc
            | stderr: append_capped(acc.stderr, IO.iodata_to_binary(data))
          })

        {:ssh_cm, ^conn_ref, {:eof, ^channel}} ->
          collect_channel_output(conn_ref, channel, deadline, acc)

        {:ssh_cm, ^conn_ref, {:exit_signal, ^channel, _signal, _msg, _lang}} ->
          collect_channel_output(conn_ref, channel, deadline, acc)

        {:ssh_cm, ^conn_ref, {:exit_status, ^channel, status}} ->
          collect_channel_output(conn_ref, channel, deadline, %{acc | exit_status: status})

        {:ssh_cm, ^conn_ref, {:closed, ^channel}} ->
          {:ok, Map.put(acc, :timed_out, false)}
      after
        remaining ->
          {:ok, %{acc | timed_out: true}}
      end
    end
  end

  defp append_capped(existing, new) do
    combined = existing <> new
    # Cap at 500KB to prevent memory exhaustion
    if byte_size(combined) > 500_000 do
      binary_part(combined, 0, 500_000)
    else
      combined
    end
  end

  # -- Private: error redaction -------------------------------------------------

  defp redact_connect_error(reason) when is_atom(reason) do
    case reason do
      :timeout -> "SSH connection timed out"
      :econnrefused -> "SSH connection refused"
      :enetunreach -> "SSH network unreachable"
      :nxdomain -> "SSH host resolution failed"
      :ehostunreach -> "SSH host unreachable"
      _ -> "SSH connection failed"
    end
  end

  defp redact_connect_error({:options, _faulty_opts}) do
    "SSH connection rejected: invalid options"
  end

  defp redact_connect_error(_reason) do
    "SSH connection failed"
  end

  defp redact_exec_error(reason) when is_atom(reason) do
    case reason do
      :timeout -> "SSH command execution timed out"
      :closed -> "SSH connection closed during execution"
      _ -> "SSH command execution failed"
    end
  end

  defp redact_exec_error(_reason) do
    "SSH command execution failed"
  end
end
