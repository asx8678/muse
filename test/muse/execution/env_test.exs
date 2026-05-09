defmodule Muse.Execution.EnvTest do
  use ExUnit.Case, async: false

  alias Muse.Execution.Env

  describe "denylisted?/1" do
    test "denylists provider API keys" do
      assert Env.denylisted?("OPENAI_API_KEY")
      assert Env.denylisted?("ANTHROPIC_API_KEY")
      assert Env.denylisted?("GITHUB_TOKEN")
      assert Env.denylisted?("AWS_SECRET_ACCESS_KEY")
      assert Env.denylisted?("GOOGLE_APPLICATION_CREDENTIALS")
      assert Env.denylisted?("AZURE_CLIENT_SECRET")
    end

    test "denylists MUSE_ prefixed vars" do
      assert Env.denylisted?("MUSE_SECRET")
      assert Env.denylisted?("MUSE_INTERNAL_TOKEN")
      assert Env.denylisted?("MUSE_PROVIDER_KEY")
    end

    test "denylists secret-semantic keys" do
      assert Env.denylisted?("MY_SECRET_TOKEN")
      assert Env.denylisted?("API_KEY")
      assert Env.denylisted?("PRIVATE_KEY")
      assert Env.denylisted?("DATABASE_URL")
      assert Env.denylisted?("AUTH_TOKEN")
      assert Env.denylisted?("ACCESS_KEY")
    end

    test "denylists proxy vars" do
      assert Env.denylisted?("HTTP_PROXY")
      assert Env.denylisted?("HTTPS_PROXY")
      assert Env.denylisted?("ALL_PROXY")
      assert Env.denylisted?("NO_PROXY")
      assert Env.denylisted?("http_proxy")
      assert Env.denylisted?("https_proxy")
    end

    test "does not denylist safe vars" do
      refute Env.denylisted?("PATH")
      refute Env.denylisted?("HOME")
      refute Env.denylisted?("LANG")
      refute Env.denylisted?("MIX_ENV")
      refute Env.denylisted?("TERM")
      refute Env.denylisted?("USER")
      refute Env.denylisted?("LOGNAME")
      refute Env.denylisted?("TMPDIR")
    end

    test "case-insensitive matching" do
      assert Env.denylisted?("openai_api_key")
      assert Env.denylisted?("OpenAI_Api_Key")
      assert Env.denylisted?("GITHUB_TOKEN")
    end
  end

  describe "safe_env_map/2 — allowlist filtering" do
    test "includes only allowlisted system vars, not all of System.get_env()" do
      original = System.get_env("MUSE_TEST_FAKE_SECRET")

      try do
        System.put_env("MUSE_TEST_FAKE_SECRET", "should-not-appear")

        env = Env.safe_env_map(%{})
        # MUSE_TEST_FAKE_SECRET should not appear (not on allowlist AND denylisted)
        refute Map.has_key?(env, "MUSE_TEST_FAKE_SECRET")
      after
        if original do
          System.put_env("MUSE_TEST_FAKE_SECRET", original)
        else
          System.delete_env("MUSE_TEST_FAKE_SECRET")
        end
      end
    end

    test "includes PATH for command execution" do
      env = Env.safe_env_map(%{})
      assert Map.has_key?(env, "PATH")
      assert is_binary(env["PATH"])
      assert env["PATH"] != ""
    end

    test "includes HOME for dotfile lookup" do
      env = Env.safe_env_map(%{})
      assert Map.has_key?(env, "HOME")
    end

    test "force-includes safe defaults even if not in system env" do
      # LANG=C.UTF-8 and LC_ALL=C.UTF-8 are always set as safe defaults.
      # MIX_ENV is NOT a safe default (only TestRunner forces it).
      env = Env.safe_env_map(%{})
      assert env["LANG"] == "C.UTF-8"
      assert env["LC_ALL"] == "C.UTF-8"
    end

    test "with inherit?: false, only safe defaults and overrides" do
      env = Env.safe_env_map(%{"MY_TOOL_VAR" => "hello"}, inherit?: false)
      # Only safe defaults + overrides, no system env inheritance
      assert env["LANG"] == "C.UTF-8"
      assert env["MY_TOOL_VAR"] == "hello"
      # PATH still comes from safe defaults
      assert Map.has_key?(env, "PATH")
      # MIX_ENV is NOT a safe default — only TestRunner forces it
      refute Map.has_key?(env, "MIX_ENV")
    end
  end

  describe "safe_env_map/2 — denylist strips secrets even from overrides" do
    test "removes denylisted keys from overrides" do
      env =
        Env.safe_env_map(%{
          "OPENAI_API_KEY" => "sk-leaked-key",
          "MY_SAFE_VAR" => "hello"
        })

      refute Map.has_key?(env, "OPENAI_API_KEY")
      assert env["MY_SAFE_VAR"] == "hello"
    end

    test "removes MUSE_ prefixed keys even if explicitly passed" do
      env =
        Env.safe_env_map(%{
          "MUSE_SECRET_TOKEN" => "accidentally-passed"
        })

      refute Map.has_key?(env, "MUSE_SECRET_TOKEN")
    end

    test "removes proxy vars even if explicitly passed" do
      env =
        Env.safe_env_map(%{
          "HTTP_PROXY" => "http://evil.proxy:8080",
          "MY_CONFIG" => "safe_value"
        })

      refute Map.has_key?(env, "HTTP_PROXY")
      assert env["MY_CONFIG"] == "safe_value"
    end

    test "removes DATABASE_URL even if explicitly passed" do
      env =
        Env.safe_env_map(%{
          "DATABASE_URL" => "postgres://user:pass@host/db"
        })

      refute Map.has_key?(env, "DATABASE_URL")
    end
  end

  describe "safe_env_map/2 — user-allowed additional vars" do
    test "custom allowlist extends the safe base" do
      _env =
        Env.safe_env_map(
          %{},
          allowlist: Env.default_allowlist() ++ ["CUSTOM_BUILD_VAR"]
        )

      # If CUSTOM_BUILD_VAR is in the system env, it should be included
      original = System.get_env("CUSTOM_BUILD_VAR")

      try do
        System.put_env("CUSTOM_BUILD_VAR", "custom_value")
        env = Env.safe_env_map(%{}, allowlist: Env.default_allowlist() ++ ["CUSTOM_BUILD_VAR"])
        assert env["CUSTOM_BUILD_VAR"] == "custom_value"
      after
        if original do
          System.put_env("CUSTOM_BUILD_VAR", original)
        else
          System.delete_env("CUSTOM_BUILD_VAR")
        end
      end
    end

    test "custom allowlist still strips denylisted keys" do
      # Even if a user adds a denylisted key to the allowlist, it's stripped
      env =
        Env.safe_env_map(
          %{},
          allowlist: Env.default_allowlist() ++ ["OPENAI_API_KEY"]
        )

      # denylist is applied AFTER allowlist — defense-in-depth
      refute Map.has_key?(env, "OPENAI_API_KEY")
    end
  end

  describe "port_env/2 — Port-compatible output" do
    test "returns charlist pairs and unset markers" do
      env = Env.port_env(%{})

      # Should have both set entries (charlist pairs) and unset markers ({key, false})
      {set_entries, unset_entries} =
        Enum.split_with(env, fn
          {_k, false} -> false
          _ -> true
        end)

      assert length(set_entries) > 0
      assert length(unset_entries) > 0

      # Set entries should be charlist pairs
      for {k, v} <- set_entries do
        assert is_list(k)
        assert is_list(v)
      end

      # Unset entries should have false as value
      for {k, v} <- unset_entries do
        assert is_list(k)
        assert v == false
      end
    end

    test "includes MIX_ENV=test" do
      env = Env.port_env(%{"MIX_ENV" => "test"})

      set =
        env
        |> Enum.filter(fn
          {_k, false} -> false
          _ -> true
        end)
        |> Map.new(fn {k, v} -> {List.to_string(k), List.to_string(v)} end)

      assert set["MIX_ENV"] == "test"
    end

    test "strips denylisted keys from port env" do
      env = Env.port_env(%{"OPENAI_API_KEY" => "sk-should-not-appear"})

      set =
        env
        |> Enum.filter(fn
          {_k, false} -> false
          _ -> true
        end)
        |> Map.new(fn {k, v} -> {List.to_string(k), List.to_string(v)} end)

      refute Map.has_key?(set, "OPENAI_API_KEY")
    end

    test "provides unset markers for system env vars not in safe set" do
      original = System.get_env("MUSE_TEST_HEREDOC_SECRET")

      try do
        System.put_env("MUSE_TEST_HEREDOC_SECRET", "leaked")

        env = Env.port_env(%{})

        unset_keys =
          env
          |> Enum.filter(fn {_k, v} -> v == false end)
          |> Enum.map(fn {k, _v} -> List.to_string(k) end)

        # MUSE_TEST_HEREDOC_SECRET should be in unset markers
        assert "MUSE_TEST_HEREDOC_SECRET" in unset_keys
      after
        if original do
          System.put_env("MUSE_TEST_HEREDOC_SECRET", original)
        else
          System.delete_env("MUSE_TEST_HEREDOC_SECRET")
        end
      end
    end
  end

  describe "redact_env/1" do
    test "replaces all values with [REDACTED]" do
      env = %{"PATH" => "/usr/bin", "SECRET_TOKEN" => "abc123", "HOME" => "/home/user"}
      redacted = Env.redact_env(env)

      assert redacted["PATH"] == "[REDACTED]"
      assert redacted["SECRET_TOKEN"] == "[REDACTED]"
      assert redacted["HOME"] == "[REDACTED]"
    end

    test "preserves keys for diagnostic value" do
      env = %{"PATH" => "/usr/bin", "API_KEY" => "sk-123"}
      redacted = Env.redact_env(env)

      assert Map.has_key?(redacted, "PATH")
      assert Map.has_key?(redacted, "API_KEY")
      # Values are always redacted
      refute redacted["PATH"] == "/usr/bin"
      refute redacted["API_KEY"] == "sk-123"
    end
  end

  describe "integration — hidden fake secret" do
    test "fake secret set in system env does not appear in safe env" do
      original = System.get_env("MUSE_FAKE_OPENAI_KEY")

      try do
        System.put_env("MUSE_FAKE_OPENAI_KEY", "sk-fake-secret-key-12345")

        env = Env.safe_env_map(%{})
        refute Map.has_key?(env, "MUSE_FAKE_OPENAI_KEY")

        # Also verify Port env doesn't have it
        port_env = Env.port_env(%{})

        set =
          port_env
          |> Enum.reject(fn {_k, v} -> v == false end)
          |> Map.new(fn {k, v} -> {List.to_string(k), List.to_string(v)} end)

        refute Map.has_key?(set, "MUSE_FAKE_OPENAI_KEY")

        # Verify it has an unset marker
        unset_keys =
          port_env
          |> Enum.filter(fn {_k, v} -> v == false end)
          |> Enum.map(fn {k, _v} -> List.to_string(k) end)

        assert "MUSE_FAKE_OPENAI_KEY" in unset_keys
      after
        if original do
          System.put_env("MUSE_FAKE_OPENAI_KEY", original)
        else
          System.delete_env("MUSE_FAKE_OPENAI_KEY")
        end
      end
    end

    test "MUSE_ prefixed var is denylisted even on custom allowlist" do
      original = System.get_env("MUSE_TEST_ALLOWED_VAR")

      try do
        System.put_env("MUSE_TEST_ALLOWED_VAR", "safe_value")

        env =
          Env.safe_env_map(
            %{},
            allowlist: Env.default_allowlist() ++ ["MUSE_TEST_ALLOWED_VAR"]
          )

        # MUSE_ prefix IS denylisted — even added to custom allowlist, it's stripped
        refute Map.has_key?(env, "MUSE_TEST_ALLOWED_VAR")
      after
        if original do
          System.put_env("MUSE_TEST_ALLOWED_VAR", original)
        else
          System.delete_env("MUSE_TEST_ALLOWED_VAR")
        end
      end
    end

    test "explicitly allowed non-sensitive custom var appears in env" do
      original = System.get_env("PROJECT_BUILD_DIR")

      try do
        System.put_env("PROJECT_BUILD_DIR", "/tmp/build")

        env =
          Env.safe_env_map(
            %{},
            allowlist: Env.default_allowlist() ++ ["PROJECT_BUILD_DIR"]
          )

        assert env["PROJECT_BUILD_DIR"] == "/tmp/build"
      after
        if original do
          System.put_env("PROJECT_BUILD_DIR", original)
        else
          System.delete_env("PROJECT_BUILD_DIR")
        end
      end
    end
  end

  describe "default_allowlist/0 and denylist_patterns/0" do
    test "default_allowlist returns expected safe vars" do
      allowlist = Env.default_allowlist()
      assert "PATH" in allowlist
      assert "HOME" in allowlist
      assert "LANG" in allowlist
      assert "MIX_ENV" in allowlist
      assert "TERM" in allowlist
    end

    test "denylist_patterns returns compiled regexes" do
      patterns = Env.denylist_patterns()
      assert is_list(patterns)
      assert length(patterns) > 0

      for p <- patterns do
        assert %Regex{} = p
      end
    end
  end
end
