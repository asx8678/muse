defmodule Muse.Auth.AuthLayerContractTest do
  use ExUnit.Case, async: true

  alias Muse.Auth.{Resolver, Status}
  alias Muse.LLM.{FakeProvider, Message, ProviderConfig, Request, Response}
  alias Muse.LLM.OpenAICompatibleProvider
  alias Muse.{CommandDispatcher, Commands}

  @api_env_key "MUSE_CONTRACT_API_KEY"
  @base_url "https://api.contract.test/v1"

  describe "OpenAI-compatible auth contract" do
    test "api_key auth resolves from injected env, injects only outbound Authorization, and decodes safely" do
      token = unique_secret("sk-contract-api-key")
      parent = self()

      post_fn = fn url, options ->
        send(parent, {:post_called, url, options})
        {:ok, Req.Response.new(status: 200, body: Jason.encode!(chat_body("api key ok")))}
      end

      request =
        openai_request(%{
          auth: :api_key,
          env_key: @api_env_key,
          auth_env: %{@api_env_key => token},
          system_env?: false,
          headers: [{"X-Contract", "api-key"}]
        })

      assert {:ok, %Response{} = response} =
               OpenAICompatibleProvider.complete(request, post_fn: post_fn)

      assert response.content == "api key ok"
      assert response.finish_reason == "stop"

      assert_receive {:post_called, url, post_options}
      assert url == @base_url <> "/chat/completions"
      assert_outbound_authorization_boundary!(post_options, token)

      posted_json = Keyword.fetch!(post_options, :json)
      refute Map.has_key?(posted_json, "metadata")
      refute Map.has_key?(posted_json, "options")

      status =
        Status.render(%{
          provider_config: provider_config(auth: :api_key, env_key: @api_env_key),
          env: %{@api_env_key => token},
          auth_status: %{
            status: :configured,
            token: token,
            authorization: "Bearer #{token}",
            command_output: token
          }
        })

      assert status =~ "api_key configured"
      assert_no_secret_leak!(response, token, "decoded OpenAI-compatible response")
      assert_no_secret_leak!(status, token, "/auth status output")
      assert_no_secret_leak!(inspect(response), token, "response inspect")
      assert_no_workspace_muse_credentials!([token])
    end

    test "bearer_command auth uses injected runner only and redacts errors/status/inspect" do
      token = unique_secret("sk-contract-bearer-command")
      command = "muse-contract-command-that-must-not-execute"
      parent = self()

      runner = fn ^command ->
        send(parent, {:auth_runner_called, command})
        {:ok, token <> "\n"}
      end

      request =
        openai_request(%{
          auth: :bearer_command,
          bearer_command: command,
          auth_runner: runner
        })

      success_post_fn = fn url, options ->
        send(parent, {:success_post_called, url, options})
        {:ok, Req.Response.new(status: 200, body: Jason.encode!(chat_body("bearer ok")))}
      end

      assert {:ok, %Response{} = response} =
               OpenAICompatibleProvider.complete(request, post_fn: success_post_fn)

      assert response.content == "bearer ok"
      assert_receive {:auth_runner_called, ^command}
      assert_receive {:success_post_called, _url, success_options}
      assert_outbound_authorization_boundary!(success_options, token)
      assert_no_secret_leak!(response, token, "bearer success response")

      assert {:ok, credential} =
               Resolver.resolve(%{auth: :bearer_command, bearer_command: command},
                 auth_runner: runner
               )

      assert_receive {:auth_runner_called, ^command}
      assert_no_secret_leak!(credential, token, "bearer credential inspect")

      error_post_fn = fn _url, options ->
        send(parent, {:error_post_called, options})
        {:error, {:transport_failed, options}}
      end

      assert {:error, error_reason} =
               OpenAICompatibleProvider.complete(request, post_fn: error_post_fn)

      assert_receive {:auth_runner_called, ^command}
      assert_receive {:error_post_called, error_options}
      assert_outbound_authorization_boundary!(error_options, token)
      assert_no_secret_leak!(error_reason, token, "bearer provider error")

      status =
        Status.render(%{
          provider_config: provider_config(auth: :bearer_command, bearer_command: command),
          auth_status: %{
            status: :configured,
            token: token,
            command_output: token,
            stdout: token
          }
        })

      assert status =~ "bearer_command configured (not executed)"
      assert_no_secret_leak!(status, token, "bearer auth status")
      assert_no_secret_leak!(inspect(status), token, "bearer status inspect")
      assert_no_workspace_muse_credentials!([token])
    end

    test "codex_cache auth reads only explicit temp auth.json, injects bearer, and keeps warnings safe" do
      token = unique_secret("sk-contract-codex-cache")
      {tmp_dir, auth_path} = write_temp_codex_auth!(token)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      chmod_result = File.chmod(auth_path, 0o644)

      assert {:ok, credential} =
               Resolver.resolve(%{auth: :codex_cache, codex_cache_path: auth_path})

      assert credential.source == :codex_cache
      assert credential.value == token

      if chmod_result == :ok do
        assert {:permissive_permissions, "0600 recommended"} in credential.warnings
      end

      assert_no_secret_leak!(credential, token, "codex credential inspect")
      refute String.starts_with?(Path.expand(auth_path), File.cwd!())

      parent = self()

      post_fn = fn url, options ->
        send(parent, {:post_called, url, options})
        {:ok, Req.Response.new(status: 200, body: Jason.encode!(chat_body("codex ok")))}
      end

      request = openai_request(%{auth: :codex_cache, codex_cache_path: auth_path})

      assert {:ok, %Response{} = response} =
               OpenAICompatibleProvider.complete(request, post_fn: post_fn)

      assert response.content == "codex ok"
      assert_receive {:post_called, _url, post_options}
      assert_outbound_authorization_boundary!(post_options, token)
      assert_no_secret_leak!(response, token, "codex response")

      status =
        Status.render(%{
          provider_config: provider_config(auth: :codex_cache),
          auth_status: credential
        })

      assert status =~ "codex_cache unknown (not read)"
      assert_no_secret_leak!(status, token, "codex auth status")
      assert_no_workspace_muse_credentials!([token])
    end
  end

  describe "/auth status contract" do
    test "uses supplied context/precomputed status without shell execution or cache reads" do
      token = unique_secret("sk-contract-auth-status")
      tmp_dir = tmp_contract_dir!("auth-status")
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      sentinel_path = Path.join(tmp_dir, "shell-command-ran")
      dangerous_command = "touch #{sentinel_path}"

      assert Commands.parse("/auth status") == {:command, :auth_status}

      context = %{
        provider_config:
          provider_config(auth: :bearer_command, bearer_command: dangerous_command),
        auth_status: %{
          status: :configured,
          token: token,
          command_output: token,
          authorization: "Bearer #{token}"
        }
      }

      assert {:ok, output, []} = CommandDispatcher.dispatch(:auth_status, nil, context)
      assert output =~ "bearer_command configured (not executed)"
      refute File.exists?(sentinel_path)
      assert_no_secret_leak!(output, token, "bearer /auth status output")

      missing_cache_path = Path.join([tmp_dir, "missing-home", ".codex", "auth.json"])

      codex_context = %{
        provider_config: provider_config(auth: :codex_cache),
        codex_cache_path: missing_cache_path,
        auth_status: %{
          status: :configured,
          path: missing_cache_path,
          access_token: token,
          command_output: token
        }
      }

      assert {:ok, codex_output, []} =
               CommandDispatcher.dispatch(:auth_status, nil, codex_context)

      assert codex_output =~ "codex_cache unknown (not read)"
      refute File.exists?(missing_cache_path)
      refute codex_output =~ tmp_dir
      assert_no_secret_leak!(codex_output, token, "codex /auth status output")
      assert_no_workspace_muse_credentials!([token])
    end
  end

  describe "offline default contract" do
    test "fake provider/default path remains no-auth and never calls network/auth hooks" do
      token = unique_secret("sk-contract-fake-provider")
      parent = self()

      post_fn = fn url, options ->
        send(parent, {:unexpected_post, url, options})
        {:error, :unexpected_network}
      end

      request = %Request{
        provider: :fake,
        model: "fake-planning-model",
        messages: [Message.user("offline fake contract")],
        options: %{
          auth: :api_key,
          auth_env: %{@api_env_key => token},
          post_fn: post_fn
        }
      }

      assert {:ok, %Response{} = response} = FakeProvider.complete(request)
      assert response.content == "Placeholder response: received offline fake contract"
      refute_received {:unexpected_post, _url, _options}

      status =
        Status.render(%{provider_config: ProviderConfig.fake(), auth_status: %{token: token}})

      assert status =~ "fake provider uses no authentication"
      assert_no_secret_leak!(response, token, "fake response")
      assert_no_secret_leak!(status, token, "fake auth status")
      assert_no_workspace_muse_credentials!([token])
    end
  end

  defp openai_request(extra_options) do
    %Request{
      provider: :openai_compatible,
      model: "gpt-4.1-mini",
      wire_api: :chat_completions,
      transport: :none,
      messages: [Message.user("auth contract request")],
      stream: false,
      options:
        Map.merge(
          %{
            base_url: @base_url,
            timeout_ms: 25,
            max_retries: 0
          },
          extra_options
        )
    }
  end

  defp provider_config(overrides) do
    struct!(
      %ProviderConfig{
        id: "openai_compatible",
        name: "OpenAI Compatible Contract",
        base_url: @base_url,
        wire_api: :chat_completions,
        transport: :none,
        model: "gpt-4.1-mini",
        auth: :none,
        env_key: @api_env_key,
        timeout_ms: 25,
        max_retries: 0
      },
      overrides
    )
  end

  defp chat_body(content) do
    %{
      "id" => "chatcmpl_auth_contract",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 2, "total_tokens" => 6}
    }
  end

  defp assert_outbound_authorization_boundary!(post_options, token) do
    headers = Keyword.fetch!(post_options, :headers)
    auth_values = authorization_header_values(headers)

    assert length(auth_values) == 1, "expected exactly one outbound Authorization header"

    assert List.first(auth_values) == "Bearer #{token}",
           "expected outbound Authorization header to contain the resolved credential"

    non_auth_headers =
      Enum.reject(headers, fn {name, _value} ->
        String.downcase(to_string(name)) == "authorization"
      end)

    assert_no_secret_leak!(non_auth_headers, token, "non-Authorization outbound headers")
    assert_no_secret_leak!(Keyword.delete(post_options, :headers), token, "outbound Req options")
    assert_no_secret_leak!(Keyword.fetch!(post_options, :json), token, "outbound JSON payload")
  end

  defp authorization_header_values(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> String.downcase(to_string(name)) == "authorization" end)
    |> Enum.map(fn {_name, value} -> value end)
  end

  defp write_temp_codex_auth!(token) do
    tmp_dir = tmp_contract_dir!("codex-cache")
    auth_dir = Path.join(tmp_dir, ".codex")
    File.mkdir_p!(auth_dir)

    auth_path = Path.join(auth_dir, "auth.json")
    File.write!(auth_path, Jason.encode!(%{"access_token" => token}))

    {tmp_dir, auth_path}
  end

  defp tmp_contract_dir!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "muse-auth-layer-contract-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp unique_secret(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp assert_no_secret_leak!(term, secrets, label) do
    rendered =
      if is_binary(term),
        do: term,
        else: inspect(term, limit: :infinity, printable_limit: :infinity)

    secrets
    |> List.wrap()
    |> Enum.each(fn secret ->
      refute String.contains?(rendered, secret), "#{label} leaked a raw credential"
    end)
  end

  defp assert_no_workspace_muse_credentials!(tokens) do
    muse_dir = Path.join(File.cwd!(), ".muse")

    if File.dir?(muse_dir) do
      muse_dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.each(fn path ->
        with {:ok, %File.Stat{size: size}} when size <= 1_000_000 <- File.stat(path),
             {:ok, contents} <- File.read(path) do
          assert_no_secret_leak!(contents, tokens, "workspace .muse file")
        else
          _ -> :ok
        end
      end)
    end
  end
end
