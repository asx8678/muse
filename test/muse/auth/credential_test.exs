defmodule Muse.Auth.CredentialTest do
  use ExUnit.Case, async: true

  alias Muse.Auth.Credential

  @api_key "sk-test-core-secret-12345"
  @bearer "bearer-core-secret-token-abcdef"
  @oauth_jwt "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlLXVzZXIifQ.signature-secret"
  @metadata_secret "sk-metadata-secret-abcdef"
  @warning_secret "sk-warning-secret-abcdef"

  describe "new/1" do
    test "constructs supported credential types and populates redacted values" do
      credentials = [
        {:api_key, @api_key},
        {:bearer, @bearer},
        {:oauth_token, @oauth_jwt}
      ]

      for {type, value} <- credentials do
        assert {:ok, %Credential{} = credential} =
                 Credential.new(type: type, value: value, source: :provider_config)

        assert credential.type == type
        assert credential.value == value
        assert credential.source == :provider_config
        assert credential.redacted =~ "REDACTED"
        refute credential.redacted =~ value

        inspected = inspect(credential)
        assert inspected =~ "#Muse.Auth.Credential<"
        refute inspected =~ "sk-"
        refute inspected =~ "eyJ"
        refute_safe_surface_leaks(credential, [value])
      end
    end

    test "accepts supported sources" do
      for source <- [:env, :app_config, :provider_config, :command, :codex_cache, :prompt, :none] do
        assert {:ok, %Credential{source: ^source}} =
                 Credential.new(type: :api_key, value: @api_key, source: source)
      end
    end

    test "normalizes known string type and source values" do
      assert {:ok, credential} =
               Credential.new(%{
                 "type" => "oauth-token",
                 "value" => @oauth_jwt,
                 "source" => "codex-cache"
               })

      assert credential.type == :oauth_token
      assert credential.source == :codex_cache
      assert credential.redacted =~ "REDACTED"
      refute_safe_surface_leaks(credential, [@oauth_jwt])
    end

    test "sanitizes and bounds metadata and warnings during construction" do
      long_note = String.duplicate("x", 1_000)

      assert {:ok, credential} =
               Credential.new(
                 type: :api_key,
                 value: @api_key,
                 source: :prompt,
                 metadata: %{
                   api_key: @metadata_secret,
                   nested: %{authorization: "Bearer #{@bearer}"},
                   note: "safe note with token=#{@metadata_secret}",
                   long_note: long_note
                 },
                 warnings: [
                   "warning token=#{@warning_secret}",
                   %{secret: @warning_secret},
                   {:bearer, "Bearer #{@bearer}"}
                 ]
               )

      refute_safe_surface_leaks(credential.metadata, [@api_key, @metadata_secret, @bearer])
      refute_safe_surface_leaks(credential.warnings, [@warning_secret, @bearer])

      refute_safe_surface_leaks(credential, [@api_key, @metadata_secret, @warning_secret, @bearer])

      assert String.length(credential.metadata.long_note) <= 301
    end
  end

  describe "new!/1" do
    test "raises redaction-safe errors" do
      message =
        try do
          Credential.new!(
            type: :api_key,
            value: "",
            source: :prompt,
            metadata: %{api_key: @api_key}
          )

          flunk("expected Credential.new!/1 to raise")
        rescue
          exception in ArgumentError -> Exception.message(exception)
        end

      assert message =~ "invalid Muse.Auth.Credential"
      refute message =~ @api_key
      refute message =~ "sk-"
    end
  end

  describe "safe errors" do
    test "nil and empty values return safe errors" do
      for value <- [nil, "", "   "] do
        assert {:error, reason} = Credential.new(type: :api_key, value: value, source: :env)
        refute_safe_surface_leaks(reason, [@api_key, @bearer, @oauth_jwt])
      end
    end

    test "unsupported types and sources are rejected without leaking raw values" do
      assert {:error, type_reason} =
               Credential.new(type: "Bearer #{@api_key}", value: @api_key, source: :env)

      assert {:error, source_reason} =
               Credential.new(type: :api_key, value: @api_key, source: "token=#{@api_key}")

      for reason <- [type_reason, source_reason] do
        refute_safe_surface_leaks(reason, [@api_key])
        refute inspect(reason) =~ "sk-"
        refute inspect(reason) =~ "Bearer "
      end
    end

    test "invalid value, expiry, and metadata errors are safe" do
      cases = [
        Credential.new(type: :api_key, value: {:secret, @api_key}, source: :env),
        Credential.new(
          type: :api_key,
          value: @api_key,
          source: :env,
          expires_at: {:secret, @api_key}
        ),
        Credential.new(
          type: :api_key,
          value: @api_key,
          source: :env,
          metadata: {:secret, @api_key}
        )
      ]

      for {:error, reason} <- cases do
        refute_safe_surface_leaks(reason, [@api_key])
        refute inspect(reason) =~ "sk-"
      end
    end
  end

  describe "to_header/1" do
    test "returns raw Authorization header only through the explicit header API" do
      for {type, value} <- [api_key: @api_key, bearer: @bearer, oauth_token: @oauth_jwt] do
        credential = Credential.new!(type: type, value: value, source: :provider_config)

        assert Credential.to_header(credential) == {"Authorization", "Bearer #{value}"}
        refute_safe_surface_leaks(credential, [value])
        refute_safe_surface_leaks(Credential.to_status(credential), [value])
      end
    end

    test "header errors are safe" do
      credential = %Credential{type: :unknown, value: @api_key, source: :env, redacted: @api_key}

      assert {:error, reason} = Credential.to_header(credential)
      assert {:error, invalid_reason} = Credential.to_header(:not_a_credential)

      for error_reason <- [reason, invalid_reason] do
        refute_safe_surface_leaks(error_reason, [@api_key])
        refute inspect(error_reason) =~ "sk-"
      end
    end
  end

  describe "to_status/1 and safe_map/1" do
    test "nil status is safe none status" do
      assert Credential.to_status(nil) == %{
               type: nil,
               source: :none,
               source_ref: nil,
               expires_at: nil,
               redacted: nil,
               metadata: %{},
               warnings: []
             }
    end

    test "return public status without value or metadata/warning leaks" do
      credential =
        Credential.new!(
          type: :oauth_token,
          value: @oauth_jwt,
          source: :codex_cache,
          source_ref: "/Users/example/.codex/auth.json token=#{@oauth_jwt}",
          metadata: %{refresh_token: @metadata_secret, note: "Bearer #{@bearer}"},
          warnings: ["saw token=#{@warning_secret}"]
        )

      for status <- [Credential.to_status(credential), Credential.safe_map(credential)] do
        assert status.type == :oauth_token
        assert status.source == :codex_cache
        assert status.redacted == "[REDACTED]"
        assert Map.has_key?(status, :source_ref)
        assert Map.has_key?(status, :warnings)
        assert Map.has_key?(status, :expires_at)
        assert Map.has_key?(status, :metadata)
        refute Map.has_key?(status, :value)

        refute_safe_surface_leaks(status, [@oauth_jwt, @metadata_secret, @warning_secret, @bearer])

        refute inspect(status) =~ "eyJ"
        refute inspect(status) =~ "Bearer "
      end
    end

    test "flags unsupported type/source in manually-built structs safely" do
      credential = %Credential{
        type: "token=#{@api_key}",
        value: @api_key,
        source: "Bearer #{@bearer}",
        redacted: @api_key,
        metadata: %{secret: @metadata_secret},
        warnings: [@warning_secret]
      }

      status = Credential.to_status(credential)

      assert {:unsupported, _type} = status.type
      assert {:unsupported, _source} = status.source
      refute Map.has_key?(status, :value)
      refute_safe_surface_leaks(status, [@api_key, @bearer, @metadata_secret, @warning_secret])
      refute inspect(status) =~ "sk-"
      refute inspect(status) =~ "Bearer "
    end
  end

  describe "present?/1 and expired?/2" do
    test "present?/1 handles credentials and non-credentials" do
      assert Credential.present?(Credential.new!(type: :api_key, value: @api_key, source: :env))
      refute Credential.present?(%Credential{type: :api_key, value: "", source: :env})
      refute Credential.present?(%Credential{type: :api_key, value: nil, source: :env})
      refute Credential.present?(nil)
    end

    test "expired?/2 handles nil, future, and past DateTime values" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 60, :second)
      past = DateTime.add(now, -60, :second)

      refute Credential.expired?(
               Credential.new!(type: :bearer, value: @bearer, source: :command),
               now
             )

      refute Credential.expired?(
               Credential.new!(
                 type: :bearer,
                 value: @bearer,
                 source: :command,
                 expires_at: future
               ),
               now
             )

      assert Credential.expired?(
               Credential.new!(type: :bearer, value: @bearer, source: :command, expires_at: past),
               now
             )

      assert Credential.expired?(
               Credential.new!(type: :bearer, value: @bearer, source: :command, expires_at: now),
               now
             )

      refute Credential.expired?(nil, now)
    end
  end

  defp refute_safe_surface_leaks(term, secrets) do
    rendered = inspect(term)

    for secret <- secrets do
      refute rendered =~ secret,
             "expected #{rendered} not to include secret #{inspect(secret)}"
    end
  end
end
