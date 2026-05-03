defmodule MuseWeb.EndpointStaticTest do
  use ExUnit.Case, async: true

  describe "static asset packaging" do
    test "priv/static/assets/css/app.css exists after assets build" do
      path = Path.join([:code.priv_dir(:muse), "static", "assets", "css", "app.css"])
      assert File.exists?(path), "Expected #{path} to exist — run `mix muse.assets` to generate"
    end

    test "priv/static/assets/app.js exists after assets build" do
      path = Path.join([:code.priv_dir(:muse), "static", "assets", "app.js"])
      assert File.exists?(path), "Expected #{path} to exist — run `mix muse.assets` to generate"
    end

    test "priv/static/images contains expected image files" do
      images_dir = Path.join([:code.priv_dir(:muse), "static", "images"])
      assert File.dir?(images_dir), "Expected #{images_dir} directory to exist"

      expected =
        ~w(muse-logo-header.png muse-bg-main.png muse-bg-sidebar.png muse-bg-light.png muse-bg-dark.png)

      for name <- expected do
        path = Path.join(images_dir, name)
        assert File.exists?(path), "Expected #{path} to exist — run `mix muse.assets` to generate"
      end
    end
  end

  describe "Plug.Static configuration" do
    test "endpoint source uses {:muse, ...} OTP app references for all static plugs" do
      source = File.read!("lib/muse_web/endpoint.ex")

      # Extract all Plug.Static from: values from the source
      from_refs =
        Regex.scan(~r/from:\s*(\{[^}]+\}|"[^"]+")/, source)
        |> Enum.map(&List.last/1)

      assert length(from_refs) >= 2,
             "Expected at least 2 Plug.Static from references, found #{length(from_refs)}"

      for ref <- from_refs do
        assert ref =~ "{:muse,",
               "Plug.Static from should use {:muse, ...} OTP app reference, got: #{ref}"
      end
    end

    test "no Plug.Static references raw source directories like assets/ or assets/images" do
      source = File.read!("lib/muse_web/endpoint.ex")

      # Old config served from "assets" and "assets/images" — these break in release
      refute source =~ ~r/from:\s*"assets(?:\/images)?"/,
             "Endpoint should not reference raw source directories in Plug.Static from"
    end
  end
end
