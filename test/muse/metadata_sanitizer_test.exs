defmodule Muse.MetadataSanitizerTest do
  use ExUnit.Case, async: true

  alias Muse.MetadataSanitizer

  # -- Redaction tests ----------------------------------------------------------

  describe "sensitive key redaction" do
    test "redacts atom keys matching sensitive patterns" do
      assert MetadataSanitizer.sanitize(%{token: "abc123"}) == %{token: "**REDACTED**"}
      assert MetadataSanitizer.sanitize(%{secret: "shhh"}) == %{secret: "**REDACTED**"}
      assert MetadataSanitizer.sanitize(%{password: "hunter2"}) == %{password: "**REDACTED**"}
      assert MetadataSanitizer.sanitize(%{api_key: "key123"}) == %{api_key: "**REDACTED**"}
      assert MetadataSanitizer.sanitize(%{csrf_token: "tok"}) == %{csrf_token: "**REDACTED**"}

      assert MetadataSanitizer.sanitize(%{authorization: "Bearer x"}) == %{
               authorization: "**REDACTED**"
             }

      assert MetadataSanitizer.sanitize(%{cookie: "session=abc"}) == %{cookie: "**REDACTED**"}
      assert MetadataSanitizer.sanitize(%{access_token: "at"}) == %{access_token: "**REDACTED**"}
      assert MetadataSanitizer.sanitize(%{bearer: "b"}) == %{bearer: "**REDACTED**"}
    end

    test "redacts string keys matching sensitive patterns (case-insensitive)" do
      assert MetadataSanitizer.sanitize(%{"Token" => "abc"}) == %{"Token" => "**REDACTED**"}
      assert MetadataSanitizer.sanitize(%{"PASSWORD" => "x"}) == %{"PASSWORD" => "**REDACTED**"}
      assert MetadataSanitizer.sanitize(%{"Api_Key" => "k"}) == %{"Api_Key" => "**REDACTED**"}

      assert MetadataSanitizer.sanitize(%{"my_secret_field" => "v"}) == %{
               "my_secret_field" => "**REDACTED**"
             }
    end

    test "preserves non-sensitive keys as atoms" do
      result = MetadataSanitizer.sanitize(%{source: :test, file: "lib/muse.ex", line: 42})

      # Atom keys are preserved
      assert Map.has_key?(result, :source)
      assert Map.has_key?(result, :file)
      assert Map.has_key?(result, :line)
      # Values are sanitized (atom → string)
      assert result[:source] == "test"
      assert result[:file] == "lib/muse.ex"
      assert result[:line] == 42
    end

    test "redacts deeply nested sensitive keys" do
      input = %{config: %{database: %{password: "db_pass"}, app: %{name: "muse"}}}
      result = MetadataSanitizer.sanitize(input, max_depth: 5)

      assert result[:config][:app][:name] == "muse"
      assert result[:config][:database][:password] == "**REDACTED**"
    end
  end

  describe "sensitive_key?/1" do
    test "detects atom keys" do
      assert MetadataSanitizer.sensitive_key?(:token)
      assert MetadataSanitizer.sensitive_key?(:api_key)
      assert MetadataSanitizer.sensitive_key?(:password)
      refute MetadataSanitizer.sensitive_key?(:source)
      refute MetadataSanitizer.sensitive_key?(:file)
    end

    test "detects string keys case-insensitively" do
      assert MetadataSanitizer.sensitive_key?("Token")
      assert MetadataSanitizer.sensitive_key?("API_KEY")
      assert MetadataSanitizer.sensitive_key?("my_password_reset")
      assert MetadataSanitizer.sensitive_key?("x-api-key")
      refute MetadataSanitizer.sensitive_key?("filename")
      refute MetadataSanitizer.sensitive_key?("source")
    end

    test "returns false for non-string/non-atom keys" do
      refute MetadataSanitizer.sensitive_key?(123)
      refute MetadataSanitizer.sensitive_key?(nil)
    end
  end

  # -- Depth limiting tests -----------------------------------------------------

  describe "depth limiting" do
    test "truncates values beyond max depth" do
      nested = %{a: %{b: %{c: %{d: "deep"}}}}
      result = MetadataSanitizer.sanitize(nested, max_depth: 2)

      # At depth 2, the innermost value should be a truncated inspect string
      assert is_map(result[:a])
      assert is_map(result[:a][:b])
      # depth 2: c value is beyond limit, so it becomes a string
      assert is_binary(result[:a][:b][:c])
    end

    test "default depth of 3 allows reasonable nesting" do
      three_deep = %{a: %{b: %{c: "ok"}}}
      result = MetadataSanitizer.sanitize(three_deep)
      assert result[:a][:b][:c] == "ok"
    end
  end

  # -- Size bounding tests ------------------------------------------------------

  describe "map key limiting" do
    test "truncates maps with too many keys" do
      big_map = for i <- 1..50, into: %{}, do: {:"key_#{i}", i}
      result = MetadataSanitizer.sanitize(big_map, max_map_keys: 5)

      assert map_size(result) == 5
      # Atom keys preserved
      assert is_atom(elem(Enum.at(result, 0), 0))
    end
  end

  describe "list length limiting" do
    test "truncates long lists" do
      long_list = Enum.to_list(1..100)
      result = MetadataSanitizer.sanitize(%{items: long_list}, max_list_length: 5)

      assert length(result[:items]) == 5
      assert result[:items] == [1, 2, 3, 4, 5]
    end
  end

  describe "string truncation" do
    test "truncates long strings with ellipsis" do
      long = String.duplicate("x", 600)
      result = MetadataSanitizer.sanitize(%{data: long}, max_string_len: 100)

      assert String.length(result[:data]) == 101
      assert String.ends_with?(result[:data], "…")
    end

    test "preserves short strings" do
      result = MetadataSanitizer.sanitize(%{data: "short"})
      assert result[:data] == "short"
    end
  end

  # -- Term normalization tests -------------------------------------------------

  describe "atom conversion" do
    test "converts atom values to strings" do
      result = MetadataSanitizer.sanitize(%{module: Muse})
      assert result[:module] == "Elixir.Muse"
      # Atom keys are preserved
      assert Map.has_key?(result, :module)
    end

    test "preserves nil, true, false as JSON-compatible" do
      result = MetadataSanitizer.sanitize(%{a: nil, b: true, c: false})
      assert result[:a] == nil
      assert result[:b] == true
      assert result[:c] == false
    end
  end

  describe "pid and reference conversion" do
    test "converts pids to inspect strings" do
      pid = self()
      result = MetadataSanitizer.sanitize(%{pid: pid})
      assert is_binary(result[:pid])
      assert result[:pid] == inspect(pid)
    end

    test "converts references to inspect strings" do
      ref = make_ref()
      result = MetadataSanitizer.sanitize(%{ref: ref})
      assert is_binary(result[:ref])
      assert result[:ref] == inspect(ref)
    end
  end

  describe "tuple conversion" do
    test "converts tuples to lists" do
      result = MetadataSanitizer.sanitize(%{coords: {1, 2, 3}})
      assert result[:coords] == [1, 2, 3]
    end
  end

  describe "struct handling" do
    test "converts structs to maps with __struct__ key" do
      dt = ~U[2024-01-01 00:00:00Z]
      result = MetadataSanitizer.sanitize(%{ts: dt})

      assert is_map(result[:ts])
      assert Map.has_key?(result[:ts], "__struct__")
    end
  end

  describe "list sanitization" do
    test "sanitizes list elements" do
      result = MetadataSanitizer.sanitize(%{keys: [:atom1, :atom2]})
      assert result[:keys] == ["atom1", "atom2"]
    end
  end

  # -- Edge cases ---------------------------------------------------------------

  describe "edge cases" do
    test "handles empty map" do
      assert MetadataSanitizer.sanitize(%{}) == %{}
    end

    test "handles empty list" do
      assert MetadataSanitizer.sanitize([]) == []
    end

    test "handles bare string" do
      assert is_binary(MetadataSanitizer.sanitize("hello"))
    end

    test "handles bare number" do
      assert MetadataSanitizer.sanitize(42) == 42
    end

    test "handles bare atom" do
      assert MetadataSanitizer.sanitize(:ok) == "ok"
    end

    test "handles nil" do
      assert MetadataSanitizer.sanitize(nil) == nil
    end

    test "handles function values" do
      fun = fn -> :ok end
      result = MetadataSanitizer.sanitize(%{callback: fun})
      assert is_binary(result[:callback])
    end

    test "mixed map with sensitive and safe keys" do
      input = %{token: "secret", source: :test, count: 42, password: "pw"}
      result = MetadataSanitizer.sanitize(input)

      assert result[:token] == "**REDACTED**"
      assert result[:source] == "test"
      assert result[:count] == 42
      assert result[:password] == "**REDACTED**"
    end
  end

  # -- Integration-style tests ---------------------------------------------------

  describe "realistic metadata shapes" do
    test "sanitizes logger-style metadata" do
      input = %{
        application: :muse,
        mfa: {Muse.Backend, :init, 1},
        file: "lib/muse/backend.ex",
        line: 42,
        pid: self(),
        time: System.system_time()
      }

      result = MetadataSanitizer.sanitize(input)

      assert result[:application] == "muse"
      assert is_list(result[:mfa])
      assert result[:file] == "lib/muse/backend.ex"
      assert result[:line] == 42
      assert is_binary(result[:pid])
      assert is_integer(result[:time])
    end

    test "sanitizes metadata with sensitive headers" do
      input = %{
        request_headers: %{
          "authorization" => "Bearer super-secret-token",
          "content-type" => "application/json",
          "x-api-key" => "key-123"
        }
      }

      result = MetadataSanitizer.sanitize(input, max_depth: 5)

      assert result[:request_headers]["authorization"] == "**REDACTED**"
      assert result[:request_headers]["content-type"] == "application/json"
      assert result[:request_headers]["x-api-key"] == "**REDACTED**"
    end

    test "sanitizes deeply nested config" do
      input = %{
        config: %{
          database: %{
            host: "localhost",
            password: "db_pass_123",
            pool: 10
          },
          auth: %{
            client_id: "muse-app",
            client_secret: "ssshhh",
            redirect_uri: "http://localhost"
          }
        }
      }

      result = MetadataSanitizer.sanitize(input, max_depth: 5)

      assert result[:config][:database][:host] == "localhost"
      assert result[:config][:database][:password] == "**REDACTED**"
      assert result[:config][:database][:pool] == 10
      assert result[:config][:auth][:client_id] == "muse-app"
      assert result[:config][:auth][:client_secret] == "**REDACTED**"
      assert result[:config][:auth][:redirect_uri] == "http://localhost"
    end
  end
end
