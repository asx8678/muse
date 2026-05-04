defmodule Muse.Prompt.DebugPreview do
  @moduledoc """
  Renders a human-readable, redacted preview of a prompt bundle.

  The debug preview shows layer metadata, active Muse, model, tools,
  and truncated/redacted content where safe. It **never** includes raw
  secrets, API keys, bearer tokens, private keys, or unredacted
  `.env` content.

  ## Visibility rules

    * `:internal` layers — show id, title, visibility, token estimate;
      do NOT show content
    * `:debug_preview` layers — show id, title, visibility, token estimate,
      and redacted/truncated content preview
    * `:user_visible` layers — show id, title, visibility, token estimate,
      and redacted/truncated content preview

  ## API

    * `render(bundle, opts \\ [])` — returns a formatted string preview

  ## Options

    * `:content_max_length` — max characters per content preview (default 200)
  """

  alias Muse.Prompt.{Bundle, Redactor}

  @default_content_max_length 200

  @doc """
  Render a redacted, human-readable debug preview of a prompt bundle.

  The output includes session id, active Muse, model, available tools,
  blocked tools, and a layer-by-layer summary with redacted content
  previews only for non-internal layers.
  """
  @spec render(Bundle.t(), keyword()) :: String.t()
  def render(bundle, opts \\ []) do
    content_max = Keyword.get(opts, :content_max_length, @default_content_max_length)

    blocked = Map.get(bundle.metadata || %{}, :blocked_tools, [])

    sections = [
      header_section(bundle),
      tools_section(bundle.tools, blocked),
      layers_section(bundle.layers, content_max)
    ]

    sections
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # -- Section builders ---------------------------------------------------------

  defp header_section(bundle) do
    lines = [
      "Prompt bundle for session #{bundle.session_id || "(unknown)"}",
      "Active Muse: #{muse_display_name(bundle.muse_id)}",
      "Model: #{bundle.model || "(default)"}"
    ]

    Enum.join(lines, "\n")
  end

  defp tools_section(tools, blocked) do
    available_names = Enum.map(tools || [], & &1[:name])
    blocked_names = blocked || []

    "Tools: #{Enum.join(available_names, ", ")}\nBlocked tools: #{Enum.join(blocked_names, ", ")}"
  end

  defp layers_section(layers, content_max) do
    lines =
      layers
      |> Enum.with_index(1)
      |> Enum.map(fn {layer, idx} ->
        layer_line(idx, layer, content_max)
      end)

    "Layers:\n" <> Enum.join(lines, "\n")
  end

  defp layer_line(idx, layer, content_max) do
    base =
      "#{idx}. #{layer.id}" <>
        String.duplicate(" ", max(1, 30 - String.length("#{layer.id}"))) <>
        "#{layer.visibility}" <>
        String.duplicate(" ", max(1, 12 - String.length("#{layer.visibility}"))) <>
        "#{layer.token_estimate || 0} tokens"

    if layer.visibility == :internal do
      # Internal layers: no content preview
      base
    else
      # Debug_preview and user_visible: show redacted + truncated content
      preview =
        Redactor.preview_text(layer.content || "", max_length: content_max)

      base <> "\n   " <> preview
    end
  end

  # -- Helpers ------------------------------------------------------------------

  defp muse_display_name(muse_id) when is_atom(muse_id) do
    case Muse.MuseRegistry.get(muse_id) do
      %{display_name: name} -> name
      nil -> "#{muse_id}"
    end
  end

  defp muse_display_name(other), do: "#{other}"
end
