defmodule Muse.LLM.ProfileLoaderTest do
  use ExUnit.Case

  alias Muse.LLM.ProfileLoader

  @valid_config %{
    "profiles" => %{
      "default" => %{
        "provider" => "openai_compatible",
        "model" => "gpt-4o",
        "base_url" => "https://api.openai.com/v1",
        "api_key" => "sk-test",
        "tools_enabled" => true,
        "structured_outputs_enabled" => true
      },
      "wafer" => %{
        "provider" => "openai_compatible",
        "model" => "glm-5.1",
        "base_url" => "https://api.wafer.ai/v1",
        "api_key" => "$WAFER_API_KEY",
        "tools_enabled" => false,
        "structured_outputs_enabled" => false
      },
      "secrets_ref" => %{
        "provider" => "openai_compatible",
        "model" => "gpt-4o",
        "base_url" => "https://api.openai.com/v1",
        "api_key" => "my_openai_key",
        "tools_enabled" => true,
        "structured_outputs_enabled" => true
      }
    }
  }

  @valid_secrets %{
    "my_openai_key" => "sk-secret-from-secrets",
    "my_wafer_key" => "wafer-secret-from-secrets"
  }

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "muse-profile-loader-test-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, tmp_dir: dir}
  end

  defp write_temp_file!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, Jason.encode!(content))

    if String.contains?(name, "secrets") do
      File.chmod!(path, 0o600)
    end

    path
  end

  # ---------------------------------------------------------------------------
  # load/1
  # ---------------------------------------------------------------------------

  describe "load/1" do
    test "returns profiles from a valid config file", %{tmp_dir: dir} do
      path = write_temp_file!(dir, "config.json", @valid_config)
      assert {:ok, profiles} = ProfileLoader.load(path)
      assert map_size(profiles) == 3
      assert get_in(profiles, ["default", "model"]) == "gpt-4o"
    end

    test "returns :not_found when file is missing" do
      assert {:error, :not_found} = ProfileLoader.load("/nonexistent/config.json")
    end

    test "returns error when profiles key is missing", %{tmp_dir: dir} do
      path = write_temp_file!(dir, "bad.json", %{"other" => true})
      assert {:error, :missing_profiles_key} = ProfileLoader.load(path)
    end
  end

  # ---------------------------------------------------------------------------
  # load_secrets/1
  # ---------------------------------------------------------------------------

  describe "load_secrets/1" do
    test "returns secrets from a valid secrets file", %{tmp_dir: dir} do
      path = write_temp_file!(dir, "secrets.json", @valid_secrets)
      assert {:ok, secrets} = ProfileLoader.load_secrets(path)
      assert secrets["my_openai_key"] == "sk-secret-from-secrets"
    end

    test "returns empty map when file is missing" do
      assert {:ok, %{}} = ProfileLoader.load_secrets("/nonexistent/secrets.json")
    end

    test "returns error for invalid JSON", %{tmp_dir: dir} do
      path = Path.join(dir, "bad_secrets.json")
      File.write!(path, "not json")
      File.chmod!(path, 0o600)
      assert {:error, _} = ProfileLoader.load_secrets(path)
    end

    test "returns error for non-object JSON", %{tmp_dir: dir} do
      path = write_temp_file!(dir, "array_secrets.json", [1, 2, 3])
      assert {:error, :invalid_secrets_format} = ProfileLoader.load_secrets(path)
    end

    test "warns when permissions are too open", %{tmp_dir: dir} do
      path = write_temp_file!(dir, "secrets.json", @valid_secrets)
      File.chmod!(path, 0o644)

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, _} = ProfileLoader.load_secrets(path)
        end)

      assert warning =~ "permissions"
      assert warning =~ "chmod 600"
    end
  end

  # ---------------------------------------------------------------------------
  # ensure_initialized/2
  # ---------------------------------------------------------------------------

  describe "ensure_initialized/2" do
    test "creates missing config and secrets files", %{tmp_dir: dir} do
      config_path = Path.join(dir, "config.json")
      secrets_path = Path.join(dir, "secrets.json")

      refute File.exists?(config_path)
      refute File.exists?(secrets_path)

      assert :ok = ProfileLoader.ensure_initialized(config_path, secrets_path)

      assert File.exists?(config_path)
      assert File.exists?(secrets_path)

      assert {:ok, config} = ProfileLoader.load(config_path)
      assert get_in(config, ["default", "provider"]) == "fake"

      assert {:ok, secrets} = ProfileLoader.load_secrets(secrets_path)
      assert secrets == %{}
    end

    test "does not overwrite existing files", %{tmp_dir: dir} do
      config_path = write_temp_file!(dir, "config.json", @valid_config)
      secrets_path = write_temp_file!(dir, "secrets.json", @valid_secrets)

      assert :ok = ProfileLoader.ensure_initialized(config_path, secrets_path)

      assert {:ok, config} = ProfileLoader.load(config_path)
      assert map_size(config) == 3

      assert {:ok, secrets} = ProfileLoader.load_secrets(secrets_path)
      assert map_size(secrets) == 2
    end

    test "creates directory if missing", %{tmp_dir: dir} do
      nested_dir = Path.join([dir, "nested", "muse"])
      config_path = Path.join(nested_dir, "config.json")
      secrets_path = Path.join(nested_dir, "secrets.json")

      assert :ok = ProfileLoader.ensure_initialized(config_path, secrets_path)
      assert File.exists?(config_path)
      assert File.exists?(secrets_path)
    end
  end

  # ---------------------------------------------------------------------------
  # get_profile/2
  # ---------------------------------------------------------------------------

  describe "get_profile/2" do
    test "returns a single profile with resolved literal api_key", %{tmp_dir: dir} do
      config_path = write_temp_file!(dir, "config.json", @valid_config)
      secrets_path = write_temp_file!(dir, "secrets.json", %{})

      assert {:ok, profile} = ProfileLoader.get_profile("default", config_path, secrets_path)
      assert profile["provider"] == "openai_compatible"
      assert profile["api_key"] == "sk-test"
    end

    test "resolves $ENV_VAR api_key references", %{tmp_dir: dir} do
      System.put_env("WAFER_API_KEY", "wafer-secret")
      config_path = write_temp_file!(dir, "config.json", @valid_config)
      secrets_path = write_temp_file!(dir, "secrets.json", %{})

      assert {:ok, profile} = ProfileLoader.get_profile("wafer", config_path, secrets_path)
      assert profile["api_key"] == "wafer-secret"
    after
      System.delete_env("WAFER_API_KEY")
    end

    test "resolves secrets file references", %{tmp_dir: dir} do
      config_path = write_temp_file!(dir, "config.json", @valid_config)
      secrets_path = write_temp_file!(dir, "secrets.json", @valid_secrets)

      assert {:ok, profile} =
               ProfileLoader.get_profile("secrets_ref", config_path, secrets_path)

      assert profile["api_key"] == "sk-secret-from-secrets"
    end

    test "falls back to literal when secret key is missing", %{tmp_dir: dir} do
      config_path = write_temp_file!(dir, "config.json", @valid_config)
      secrets_path = write_temp_file!(dir, "secrets.json", %{})

      assert {:ok, profile} =
               ProfileLoader.get_profile("secrets_ref", config_path, secrets_path)

      assert profile["api_key"] == "my_openai_key"
    end

    test "returns :profile_not_found for unknown names", %{tmp_dir: dir} do
      config_path = write_temp_file!(dir, "config.json", @valid_config)
      secrets_path = write_temp_file!(dir, "secrets.json", %{})

      assert {:error, :profile_not_found} =
               ProfileLoader.get_profile("unknown", config_path, secrets_path)
    end

    test "returns :not_found when config file is absent" do
      assert {:error, :not_found} =
               ProfileLoader.get_profile("default", "/nonexistent/config.json")
    end
  end

  # ---------------------------------------------------------------------------
  # to_env_map/1
  # ---------------------------------------------------------------------------

  describe "to_env_map/1" do
    test "converts a profile into MUSE_* variables" do
      profile = %{
        "provider" => "openai_compatible",
        "model" => "gpt-4o",
        "base_url" => "https://api.openai.com/v1",
        "api_key" => "sk-test",
        "tools_enabled" => true,
        "structured_outputs_enabled" => false
      }

      env = ProfileLoader.to_env_map(profile)

      assert env["MUSE_PROVIDER"] == "openai_compatible"
      assert env["MUSE_MODEL"] == "gpt-4o"
      assert env["MUSE_OPENAI_BASE_URL"] == "https://api.openai.com/v1"
      assert env["MUSE_OPENAI_API_KEY"] == "sk-test"
      assert env["MUSE_TOOLS"] == "true"
      assert env["MUSE_STRUCTURED_OUTPUTS"] == "false"
    end

    test "omits base_url and api_key when blank" do
      profile = %{
        "provider" => "fake",
        "model" => "fake-planning-model",
        "tools_enabled" => nil,
        "structured_outputs_enabled" => nil
      }

      env = ProfileLoader.to_env_map(profile)

      assert env["MUSE_PROVIDER"] == "fake"
      assert env["MUSE_MODEL"] == "fake-planning-model"
      refute Map.has_key?(env, "MUSE_BASE_URL")
      refute Map.has_key?(env, "MUSE_API_KEY")
      assert env["MUSE_TOOLS"] == ""
      assert env["MUSE_STRUCTURED_OUTPUTS"] == ""
    end
  end

  # ---------------------------------------------------------------------------
  # apply_profile/2
  # ---------------------------------------------------------------------------

  describe "apply_profile/2" do
    test "sets environment variables from a profile", %{tmp_dir: dir} do
      config_path = write_temp_file!(dir, "config.json", @valid_config)
      secrets_path = write_temp_file!(dir, "secrets.json", %{})

      assert :ok = ProfileLoader.apply_profile("default", config_path, secrets_path)

      assert System.get_env("MUSE_PROVIDER") == "openai_compatible"
      assert System.get_env("MUSE_MODEL") == "gpt-4o"
      assert System.get_env("MUSE_OPENAI_BASE_URL") == "https://api.openai.com/v1"
      assert System.get_env("MUSE_OPENAI_API_KEY") == "sk-test"
      assert System.get_env("MUSE_TOOLS") == "true"
      assert System.get_env("MUSE_STRUCTURED_OUTPUTS") == "true"
    after
      for key <- [
            "MUSE_PROVIDER",
            "MUSE_MODEL",
            "MUSE_OPENAI_BASE_URL",
            "MUSE_OPENAI_API_KEY",
            "MUSE_TOOLS",
            "MUSE_STRUCTURED_OUTPUTS"
          ] do
        System.delete_env(key)
      end
    end

    test "resolves secrets when applying a profile", %{tmp_dir: dir} do
      config_path = write_temp_file!(dir, "config.json", @valid_config)
      secrets_path = write_temp_file!(dir, "secrets.json", @valid_secrets)

      assert :ok = ProfileLoader.apply_profile("secrets_ref", config_path, secrets_path)
      assert System.get_env("MUSE_OPENAI_API_KEY") == "sk-secret-from-secrets"
    after
      for key <- [
            "MUSE_PROVIDER",
            "MUSE_MODEL",
            "MUSE_OPENAI_BASE_URL",
            "MUSE_OPENAI_API_KEY",
            "MUSE_TOOLS",
            "MUSE_STRUCTURED_OUTPUTS"
          ] do
        System.delete_env(key)
      end
    end

    test "returns :not_found when config file is absent" do
      assert {:error, :not_found} =
               ProfileLoader.apply_profile("default", "/nonexistent/config.json")
    end
  end

  # ---------------------------------------------------------------------------
  # current_profile_name/0
  # ---------------------------------------------------------------------------

  describe "current_profile_name/0" do
    test "returns 'default' when MUSE_PROFILE is unset" do
      System.delete_env("MUSE_PROFILE")
      assert ProfileLoader.current_profile_name() == "default"
    end

    test "returns MUSE_PROFILE value when set" do
      System.put_env("MUSE_PROFILE", "wafer")
      assert ProfileLoader.current_profile_name() == "wafer"
    after
      System.delete_env("MUSE_PROFILE")
    end
  end

  # ---------------------------------------------------------------------------
  # get_profile/0
  # ---------------------------------------------------------------------------

  describe "get_profile/0" do
    test "loads the active profile (default) from the default path", %{tmp_dir: dir} do
      System.delete_env("MUSE_PROFILE")

      path = write_temp_file!(dir, "config.json", @valid_config)

      assert {:ok, profile} =
               ProfileLoader.get_profile(ProfileLoader.current_profile_name(), path)

      assert profile["provider"] == "openai_compatible"
      assert profile["model"] == "gpt-4o"
    end

    test "loads the active profile when MUSE_PROFILE is set", %{tmp_dir: dir} do
      System.put_env("MUSE_PROFILE", "wafer")
      System.put_env("WAFER_API_KEY", "wafer-secret")

      path = write_temp_file!(dir, "config.json", @valid_config)

      assert {:ok, profile} =
               ProfileLoader.get_profile(ProfileLoader.current_profile_name(), path)

      assert profile["provider"] == "openai_compatible"
      assert profile["model"] == "glm-5.1"
      assert profile["api_key"] == "wafer-secret"
    after
      System.delete_env("MUSE_PROFILE")
      System.delete_env("WAFER_API_KEY")
    end
  end

  # ---------------------------------------------------------------------------
  # apply_profile/0
  # ---------------------------------------------------------------------------

  describe "apply_profile/0" do
    test "applies the active profile (default)", %{tmp_dir: dir} do
      System.delete_env("MUSE_PROFILE")
      path = write_temp_file!(dir, "config.json", @valid_config)

      assert :ok = ProfileLoader.apply_profile(ProfileLoader.current_profile_name(), path)
      assert System.get_env("MUSE_PROVIDER") == "openai_compatible"
      assert System.get_env("MUSE_MODEL") == "gpt-4o"
    after
      for key <- [
            "MUSE_PROVIDER",
            "MUSE_MODEL",
            "MUSE_OPENAI_BASE_URL",
            "MUSE_OPENAI_API_KEY",
            "MUSE_TOOLS",
            "MUSE_STRUCTURED_OUTPUTS"
          ] do
        System.delete_env(key)
      end
    end

    test "applies the profile named by MUSE_PROFILE", %{tmp_dir: dir} do
      System.put_env("MUSE_PROFILE", "wafer")
      System.put_env("WAFER_API_KEY", "wafer-secret")
      path = write_temp_file!(dir, "config.json", @valid_config)

      assert :ok = ProfileLoader.apply_profile(ProfileLoader.current_profile_name(), path)
      assert System.get_env("MUSE_PROVIDER") == "openai_compatible"
      assert System.get_env("MUSE_MODEL") == "glm-5.1"
      assert System.get_env("MUSE_OPENAI_BASE_URL") == "https://api.wafer.ai/v1"
    after
      System.delete_env("MUSE_PROFILE")
      System.delete_env("WAFER_API_KEY")

      for key <- [
            "MUSE_PROVIDER",
            "MUSE_MODEL",
            "MUSE_OPENAI_BASE_URL",
            "MUSE_OPENAI_API_KEY",
            "MUSE_TOOLS",
            "MUSE_STRUCTURED_OUTPUTS"
          ] do
        System.delete_env(key)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # merged_env/0
  # ---------------------------------------------------------------------------

  describe "merged_env/0" do
    test "merges the active profile (default) with System.get_env", %{tmp_dir: dir} do
      System.delete_env("MUSE_PROFILE")
      System.put_env("MUSE_PROVIDER", "fake")
      System.put_env("MUSE_OPENAI_API_KEY", "old-key")

      path = write_temp_file!(dir, "config.json", @valid_config)

      assert {:ok, env} = ProfileLoader.merged_env(ProfileLoader.current_profile_name(), path)
      assert env["MUSE_PROVIDER"] == "openai_compatible"
      assert env["MUSE_MODEL"] == "gpt-4o"
      assert env["MUSE_OPENAI_API_KEY"] == "sk-test"
    after
      for key <- [
            "MUSE_PROVIDER",
            "MUSE_MODEL",
            "MUSE_OPENAI_BASE_URL",
            "MUSE_OPENAI_API_KEY",
            "MUSE_TOOLS",
            "MUSE_STRUCTURED_OUTPUTS"
          ] do
        System.delete_env(key)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # merged_env/2
  # ---------------------------------------------------------------------------

  describe "merged_env/2" do
    test "returns System.get_env merged with profile overrides", %{tmp_dir: dir} do
      System.put_env("MUSE_PROVIDER", "fake")
      System.put_env("MUSE_OPENAI_API_KEY", "old-key")

      path = write_temp_file!(dir, "config.json", @valid_config)

      assert {:ok, env} = ProfileLoader.merged_env("default", path)

      assert env["MUSE_PROVIDER"] == "openai_compatible"
      assert env["MUSE_MODEL"] == "gpt-4o"
      assert env["MUSE_OPENAI_API_KEY"] == "sk-test"
      assert env["MUSE_TOOLS"] == "true"
    after
      for key <- [
            "MUSE_PROVIDER",
            "MUSE_MODEL",
            "MUSE_OPENAI_BASE_URL",
            "MUSE_OPENAI_API_KEY",
            "MUSE_TOOLS",
            "MUSE_STRUCTURED_OUTPUTS"
          ] do
        System.delete_env(key)
      end
    end

    test "merges with secrets-resolved api_key", %{tmp_dir: dir} do
      config_path = write_temp_file!(dir, "config.json", @valid_config)
      secrets_path = write_temp_file!(dir, "secrets.json", @valid_secrets)

      assert {:ok, env} = ProfileLoader.merged_env("secrets_ref", config_path, secrets_path)
      assert env["MUSE_OPENAI_API_KEY"] == "sk-secret-from-secrets"
    after
      for key <- [
            "MUSE_PROVIDER",
            "MUSE_MODEL",
            "MUSE_OPENAI_BASE_URL",
            "MUSE_OPENAI_API_KEY",
            "MUSE_TOOLS",
            "MUSE_STRUCTURED_OUTPUTS"
          ] do
        System.delete_env(key)
      end
    end
  end
end
