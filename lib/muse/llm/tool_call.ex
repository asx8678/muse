defmodule Muse.LLM.ToolCall do
  @moduledoc """
  Provider-neutral tool call struct.

  Normalized across all provider wire APIs. When a model requests a tool
  invocation, the provider adapter decodes the wire-specific format into this
  struct. The runtime dispatches based on `name` and `arguments`.

  ## Fields

    * `id`        — provider-assigned call identifier (e.g. `"call_abc123"`)
    * `name`      — the tool name the model wants to invoke
    * `arguments` — decoded map of tool arguments (never a raw JSON string)
    * `raw`       — the original provider-specific payload (for debugging)

  ## Constructor

      iex> tc = Muse.LLM.ToolCall.new("read_file", %{"path" => "lib/muse.ex"})
      iex> tc.name
      "read_file"
      iex> tc.arguments
      %{"path" => "lib/muse.ex"}
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          arguments: map(),
          raw: term() | nil
        }

  @enforce_keys [:name]
  defstruct [:id, :name, :arguments, :raw]

  @doc """
  Create a tool call with the given name and arguments.

  ## Options

    * `:id`  — optional provider-assigned call identifier
    * `:raw` — optional original provider payload
  """
  @spec new(String.t(), map(), keyword()) :: t()
  def new(name, arguments, opts \\ [])
      when is_binary(name) and (is_map(arguments) or is_nil(arguments)) do
    %__MODULE__{
      id: Keyword.get(opts, :id),
      name: name,
      arguments: arguments || %{},
      raw: Keyword.get(opts, :raw)
    }
  end
end
