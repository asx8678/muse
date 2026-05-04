defmodule Muse.Tools.AskUserQuestion do
  @moduledoc """
  Interactive tool: ask the user a clarifying question.

  Returns a non-blocking result (`answered: false`) since the model
  must wait for user input. The question text is included for
  event emission but redacted in summaries.
  """

  alias Muse.Tool.Result

  @doc """
  Execute the ask_user_question tool.

  Returns a `%Result{}` with `answered: false` and a redacted question.
  """
  @spec execute(map(), map()) :: Result.t()
  def execute(args, _context) do
    question = Map.get(args, "question", "")

    Result.ok("ask_user_question", %{
      answered: false,
      question_preview: truncate_and_redact(question)
    })
  end

  defp truncate_and_redact(text) when is_binary(text) do
    text
    |> Muse.Prompt.Redactor.redact_text()
    |> String.slice(0, 200)
  end

  defp truncate_and_redact(_), do: ""
end
