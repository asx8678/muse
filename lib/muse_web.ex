defmodule MuseWeb do
  @moduledoc """
  Entry point for MuseWeb module helpers.
  """

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
