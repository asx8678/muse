defmodule Muse.LLM.Transport.WebSocket.SafeError do
  @moduledoc false

  @summary_limit 500
  @safe_phase_prefixes ~w(connect_failed create_frame_failed send_failed receive_failed control_frame_failed)

  @doc false
  @spec phase_summary(atom(), term()) :: String.t()
  def phase_summary(phase, reason) when is_atom(phase) do
    phase_text = Atom.to_string(phase)
    reason_text = summary(reason)

    if reason_text == "" do
      phase_text
    else
      phase_text <> ": " <> reason_text
    end
  end

  @doc false
  @spec normalize_reason(term()) :: atom() | String.t()
  def normalize_reason(reason) when is_atom(reason), do: reason

  def normalize_reason(reason) when is_binary(reason) do
    raw = String.slice(reason, 0, @summary_limit)
    redacted = Muse.EventPayloadRedactor.redact_string(raw)

    cond do
      safe_generated_summary?(redacted) -> redacted
      raw != redacted -> "[REDACTED]"
      true -> "binary"
    end
  end

  def normalize_reason(reason), do: summary(reason)

  @doc false
  @spec summary(term()) :: String.t()
  def summary(reason) do
    raw = bounded_raw(reason)
    redacted = Muse.EventPayloadRedactor.redact_string(raw)

    cond do
      raw != redacted -> redacted_marker(reason)
      is_atom(reason) -> Atom.to_string(reason)
      is_binary(reason) -> "binary"
      true -> generic_summary(reason)
    end
  end

  @doc false
  @spec result_shape(term()) :: atom() | {:tuple, non_neg_integer()} | nil
  def result_shape(result) when is_atom(result), do: result
  def result_shape(result) when is_binary(result), do: :binary
  def result_shape(result) when is_map(result), do: :map
  def result_shape(result) when is_list(result), do: :list
  def result_shape(result) when is_tuple(result), do: {:tuple, tuple_size(result)}
  def result_shape(result) when is_number(result), do: :number
  def result_shape(result) when is_boolean(result), do: :boolean
  def result_shape(nil), do: nil
  def result_shape(_result), do: :term

  defp safe_generated_summary?(value) do
    case String.split(value, ": ", parts: 2) do
      [phase, tail] when phase in @safe_phase_prefixes -> safe_summary_tail?(tail)
      _other -> false
    end
  end

  defp safe_summary_tail?(tail) do
    Regex.match?(
      ~r/\A(?:[A-Za-z][A-Za-z0-9_.]*|[a-z_][a-z0-9_]*(?:: \[REDACTED\])?|\[REDACTED\]|binary|tuple|map|list|nil|true|false|-?\d+)\z/,
      tail
    )
  end

  defp bounded_raw(reason) when is_binary(reason) do
    String.slice(reason, 0, @summary_limit)
  end

  defp bounded_raw(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @summary_limit)
    |> String.slice(0, @summary_limit)
  end

  defp redacted_marker(reason) when is_binary(reason), do: "[REDACTED]"

  defp redacted_marker({tag, _rest}) when is_atom(tag),
    do: Atom.to_string(tag) <> ": [REDACTED]"

  defp redacted_marker({tag, _rest1, _rest2}) when is_atom(tag),
    do: Atom.to_string(tag) <> ": [REDACTED]"

  defp redacted_marker(reason) do
    generic_summary(reason) <> ": [REDACTED]"
  end

  defp generic_summary({tag}) when is_atom(tag), do: Atom.to_string(tag)
  defp generic_summary({tag, _rest}) when is_atom(tag), do: Atom.to_string(tag)
  defp generic_summary({tag, _rest1, _rest2}) when is_atom(tag), do: Atom.to_string(tag)
  defp generic_summary({tag, _rest1, _rest2, _rest3}) when is_atom(tag), do: Atom.to_string(tag)

  defp generic_summary(%{__struct__: module}) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp generic_summary(reason) when is_map(reason), do: "map"
  defp generic_summary(reason) when is_list(reason), do: "list"
  defp generic_summary(reason) when is_tuple(reason), do: "tuple"
  defp generic_summary(reason) when is_number(reason), do: to_string(reason)
  defp generic_summary(reason) when is_boolean(reason), do: to_string(reason)
  defp generic_summary(nil), do: "nil"
  defp generic_summary(_reason), do: "websocket_transport_error"
end
