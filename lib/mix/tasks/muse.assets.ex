defmodule Mix.Tasks.Muse.Assets do
  @shortdoc "Copy CSS & images to priv/static and build JS via esbuild"

  @moduledoc """
  Prepares static assets for serving in both source and release modes.

  Copies `assets/css` → `priv/static/assets/css` and
  `assets/images` → `priv/static/images`, then runs esbuild to produce
  `priv/static/assets/app.js`.

  ## Usage

      mix muse.assets

  This task is safe to run idempotently — it will overwrite existing
  files in `priv/static` with fresh copies from `assets/`.
  """

  use Mix.Task

  @source_root "assets"
  @target_root "priv/static"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("compile", [])

    # Ensure target directories exist
    File.mkdir_p!(Path.join(@target_root, "assets/css"))
    File.mkdir_p!(Path.join(@target_root, "images"))

    # Copy CSS files
    copy_dir(Path.join(@source_root, "css"), Path.join(@target_root, "assets/css"))

    # Copy image files
    copy_dir(Path.join(@source_root, "images"), Path.join(@target_root, "images"))

    # Build JS via esbuild (if available)
    if Code.ensure_loaded?(Esbuild) do
      Mix.Task.run("esbuild", ["default"])
    else
      Mix.shell().info("esbuild not available — skipping JS build")
    end

    :ok
  end

  # -- Private helpers -----------------------------------------------------------

  defp copy_dir(src, dest) do
    if File.dir?(src) do
      for file <- File.ls!(src), not hidden?(file), File.regular?(Path.join(src, file)) do
        src_path = Path.join(src, file)
        dest_path = Path.join(dest, file)

        File.cp!(src_path, dest_path)
        Mix.shell().info("  copied #{src_path} → #{dest_path}")
      end
    else
      Mix.shell().error("  source directory not found: #{src}")
    end
  end

  defp hidden?("." <> _), do: true
  defp hidden?(_), do: false
end
