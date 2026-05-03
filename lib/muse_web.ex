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
      use Phoenix.LiveView, log: false
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  @doc """
  Safely parse a string (or value) to an integer.

  Returns `{:ok, integer}` on success, `:error` on failure.
  Handles malformed client params without raising.

  ## Examples

      iex> MuseWeb.safe_to_integer("42")
      {:ok, 42}

      iex> MuseWeb.safe_to_integer("abc")
      :error

      iex> MuseWeb.safe_to_integer(7)
      {:ok, 7}
  """
  def safe_to_integer(value) when is_integer(value), do: {:ok, value}

  def safe_to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def safe_to_integer(_), do: :error

  @doc """
  Safely parse a value to an integer, returning `nil` on failure.

  Useful for line numbers and other optional numeric metadata.

  ## Examples

      iex> MuseWeb.safe_to_integer_or_nil("42")
      42

      iex> MuseWeb.safe_to_integer_or_nil("abc")
      nil
  """
  def safe_to_integer_or_nil(value) do
    case safe_to_integer(value) do
      {:ok, n} -> n
      :error -> nil
    end
  end
end
