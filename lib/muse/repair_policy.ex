defmodule Muse.RepairPolicy do
  @moduledoc """
  Bounded repair policy that prevents autonomous shell/test loops.

  Repair attempts are bounded: the default maximum is 2, configurable but
  clamped to an absolute ceiling of 5. This policy is the single source of
  truth for whether a repair attempt is allowed.

  ## Design decisions

    * Repair is **not** automatic. The policy only *allows* or *denies*
      a repair attempt — it never triggers one.
    * The counter is per-session (or per-context), not global.
    * Once the maximum is reached, further repair attempts return
      `{:error, :repair_budget_exhausted}`.
    * The absolute ceiling (`@absolute_max_repairs`) is not overridable
      by configuration — it is a compile-time safety bound.
    * Tests can prove the cap is enforced and a repair loop cannot
      become autonomous shell/test execution.

  ## API

    * `new/1`        — create a policy with optional overrides
    * `allow?/1`     — check if a repair attempt is permitted
    * `record/1`     — record a repair attempt (returns updated policy or error)
    * `remaining/1` — how many repair attempts are left
    * `exhausted?/1` — whether the budget is exhausted
  """

  @absolute_max_repairs 5
  @default_max_repairs 2

  @enforce_keys [:max_repairs, :attempts]
  defstruct [:max_repairs, :attempts, :session_id]

  @type t :: %__MODULE__{
          max_repairs: pos_integer(),
          attempts: non_neg_integer(),
          session_id: String.t() | nil
        }

  @doc """
  Create a new repair policy.

  ## Options

    * `:max_repairs` — maximum repair attempts (default 2, clamped to #{@absolute_max_repairs})
    * `:session_id`  — optional session identifier

  ## Examples

      iex> policy = Muse.RepairPolicy.new()
      iex> policy.max_repairs
      2
      iex> policy.attempts
      0

      iex> policy = Muse.RepairPolicy.new(max_repairs: 10)
      iex> policy.max_repairs
      5
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    requested = Keyword.get(opts, :max_repairs, @default_max_repairs)
    max_repairs = min(requested, @absolute_max_repairs) |> max(1)

    %__MODULE__{
      max_repairs: max_repairs,
      attempts: 0,
      session_id: Keyword.get(opts, :session_id)
    }
  end

  @doc """
  Check whether a repair attempt is allowed under this policy.

  ## Examples

      iex> policy = Muse.RepairPolicy.new()
      iex> Muse.RepairPolicy.allow?(policy)
      true

      iex> policy = Muse.RepairPolicy.new() |> Muse.RepairPolicy.record() |> Muse.RepairPolicy.record()
      iex> Muse.RepairPolicy.allow?(policy)
      false
  """
  @spec allow?(t()) :: boolean()
  def allow?(%__MODULE__{attempts: attempts, max_repairs: max}), do: attempts < max

  @doc """
  Record a repair attempt. Returns `{:ok, updated_policy}` if the attempt
  is allowed, or `{:error, :repair_budget_exhausted}` if the budget is
  exhausted.

  ## Examples

      iex> policy = Muse.RepairPolicy.new(max_repairs: 2)
      iex> {:ok, p1} = Muse.RepairPolicy.record(policy)
      iex> p1.attempts
      1
      iex> {:ok, p2} = Muse.RepairPolicy.record(p1)
      iex> p2.attempts
      2
      iex> {:error, :repair_budget_exhausted} = Muse.RepairPolicy.record(p2)
  """
  @spec record(t()) :: {:ok, t()} | {:error, :repair_budget_exhausted}
  def record(%__MODULE__{} = policy) do
    if allow?(policy) do
      {:ok, %{policy | attempts: policy.attempts + 1}}
    else
      {:error, :repair_budget_exhausted}
    end
  end

  @doc """
  Return the number of remaining repair attempts.

  ## Examples

      iex> policy = Muse.RepairPolicy.new(max_repairs: 2)
      iex> Muse.RepairPolicy.remaining(policy)
      2
      iex> {:ok, p1} = Muse.RepairPolicy.record(policy)
      iex> Muse.RepairPolicy.remaining(p1)
      1
  """
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{attempts: a, max_repairs: m}), do: max(m - a, 0)

  @doc """
  Check if the repair budget is exhausted.

  ## Examples

      iex> policy = Muse.RepairPolicy.new()
      iex> Muse.RepairPolicy.exhausted?(policy)
      false

      iex> policy = Muse.RepairPolicy.new() |> elem_record_n(3)
      iex> Muse.RepairPolicy.exhausted?(policy)
      true
  """
  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{} = policy), do: not allow?(policy)

  @doc """
  Return the absolute maximum repair ceiling (not overridable).
  """
  @spec absolute_max() :: pos_integer()
  def absolute_max, do: @absolute_max_repairs

  @doc """
  Return the default maximum repair attempts.
  """
  @spec default_max() :: pos_integer()
  def default_max, do: @default_max_repairs

  # Helper for doctests — apply record N times, returning last policy
  @doc false
  @spec elem_record_n(t(), non_neg_integer()) :: t()
  def elem_record_n(policy, n) do
    Enum.reduce(1..n, policy, fn _, p ->
      case record(p) do
        {:ok, updated} -> updated
        {:error, _} -> p
      end
    end)
  end
end
