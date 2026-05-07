defmodule SymphonyElixir.Resume.Reconciler do
  @moduledoc """
  Pure decision logic for crash/restart resume reconciliation.
  """

  alias SymphonyElixir.Linear.Issue

  @terminal_states MapSet.new(["cancelled", "canceled", "closed", "done", "duplicate", "merged"])

  @type boot_action ::
          :ignore
          | :park_review
          | {:block, map()}
          | {:relaunch, map()}
          | {:resume_parent, map()}

  @spec boot_action(Issue.t(), map()) :: boot_action()
  def boot_action(%Issue{} = issue, context) when is_map(context) do
    cond do
      active_runner?(issue, context) ->
        :ignore

      active_lease?(issue, context) ->
        :ignore

      cleared_parent_gate?(issue, context) ->
        {:resume_parent, resume_parent_packet(issue, context)}

      stale_working_issue?(issue, context) ->
        stale_working_action(issue, context)

      review_boundary?(issue) ->
        :park_review

      true ->
        :ignore
    end
  end

  @spec stale_working_issue?(Issue.t(), map()) :: boolean()
  def stale_working_issue?(%Issue{} = issue, context) when is_map(context) do
    normalize_state(issue.workpad_state) == "working" and stale_issue_update?(issue, context)
  end

  @spec cleared_parent_gate?(Issue.t(), map()) :: boolean()
  def cleared_parent_gate?(%Issue{} = issue, context) when is_map(context) do
    parent_gate_states = Map.get(context, :parent_gate_states, ["human review", "in review"])

    normalize_state(issue.workpad_state) == "blocked" and
      normalize_state(issue.state) in parent_gate_states and
      issue.blocked_by != [] and
      all_blockers_terminal?(issue.blocked_by, context)
  end

  defp stale_working_action(%Issue{} = issue, context) do
    case latest_checkpoint(issue, context) do
      %{} = checkpoint ->
        if safe_checkpoint?(checkpoint) do
          {:relaunch, checkpoint}
        else
          {:block, blocked_resume_packet(issue, context)}
        end

      _checkpoint ->
        {:block, blocked_resume_packet(issue, context)}
    end
  end

  defp blocked_resume_packet(%Issue{} = issue, context) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      status: "blocked",
      reason: "stale_working_without_safe_checkpoint",
      linear_state: issue.state,
      workpad_state: issue.workpad_state,
      stale_interval_ms: Map.get(context, :stale_interval_ms),
      resume_instruction: "Review the workspace manually before retrying; no safe durable boundary was available for automatic relaunch."
    }
  end

  defp resume_parent_packet(%Issue{} = issue, context) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      status: "resume_parent",
      reason: "child_gate_cleared",
      linear_state: issue.state,
      workpad_state: issue.workpad_state,
      blockers: sanitized_blockers(issue.blocked_by),
      resume_instruction: "Move the parent control issue back to Rework and continue the parent only; do not start duplicate child work.",
      checkpoint_id: latest_checkpoint(issue, context) && Map.get(latest_checkpoint(issue, context), "checkpoint_id")
    }
  end

  defp review_boundary?(%Issue{} = issue) do
    normalize_state(issue.state) in ["human review", "in review"] or
      normalize_state(issue.workpad_state) in ["ready_for_review", "ready_for_review_local"]
  end

  defp active_runner?(%Issue{id: issue_id}, context) when is_binary(issue_id) do
    context
    |> Map.get(:running_issue_ids, MapSet.new())
    |> MapSet.member?(issue_id)
  end

  defp active_runner?(_issue, _context), do: false

  defp active_lease?(%Issue{id: issue_id}, context) when is_binary(issue_id) do
    context
    |> Map.get(:active_lease_issue_ids, MapSet.new())
    |> MapSet.member?(issue_id)
  end

  defp active_lease?(_issue, _context), do: false

  defp stale_issue_update?(%Issue{updated_at: %DateTime{} = updated_at}, context) do
    now = Map.get(context, :now, DateTime.utc_now())
    interval_ms = Map.get(context, :stale_interval_ms, 10 * 60 * 1_000)
    DateTime.diff(now, updated_at, :millisecond) >= interval_ms
  end

  defp stale_issue_update?(_issue, _context), do: true

  defp latest_checkpoint(%Issue{id: issue_id}, context) when is_binary(issue_id) do
    context
    |> Map.get(:latest_checkpoints, %{})
    |> Map.get(issue_id)
  end

  defp latest_checkpoint(_issue, _context), do: nil

  defp safe_checkpoint?(checkpoint) when is_map(checkpoint) do
    Map.get(checkpoint, "safe_to_resume") in [true, "true", "yes"] and
      Map.get(checkpoint, "non_idempotent_retry_requires_review") not in [true, "true", "yes"]
  end

  defp all_blockers_terminal?(blockers, context) when is_list(blockers) do
    terminal_states =
      context
      |> Map.get(:terminal_states, @terminal_states)
      |> normalize_state_set()

    Enum.all?(blockers, fn
      %{state: state} -> MapSet.member?(terminal_states, normalize_state(state))
      %{"state" => state} -> MapSet.member?(terminal_states, normalize_state(state))
      _ -> false
    end)
  end

  defp all_blockers_terminal?(_blockers, _context), do: false

  defp sanitized_blockers(blockers) when is_list(blockers) do
    Enum.map(blockers, fn
      %{id: id, identifier: identifier, state: state} ->
        %{id: id, identifier: identifier, state: state}

      %{"id" => id, "identifier" => identifier, "state" => state} ->
        %{id: id, identifier: identifier, state: state}

      _ ->
        %{id: nil, identifier: nil, state: nil}
    end)
  end

  defp normalize_state_set(states) when is_list(states) do
    states
    |> Enum.map(&normalize_state/1)
    |> MapSet.new()
  end

  defp normalize_state_set(%MapSet{} = states), do: states
  defp normalize_state_set(_states), do: @terminal_states

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
