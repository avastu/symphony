defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, DeployIntent, Orchestrator, StatusDashboard, Workflow}
  alias SymphonyElixir.Resume.Store

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            pending_slot: length(Map.get(snapshot, :pending_slot, [])),
            retrying: length(snapshot.retrying),
            completed: Map.get(snapshot, :completed_count, 0)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          pending_slot: Enum.map(Map.get(snapshot, :pending_slot, []), &pending_slot_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          managed_projects: managed_project_payloads(),
          codex_totals: snapshot.codex_totals,
          completed_count: Map.get(snapshot, :completed_count, 0),
          rate_limits: snapshot.rate_limits,
          rate_limit_summary: rate_limit_summary(snapshot.rate_limits),
          deploy_pending: Map.get(snapshot, :deploy_pending),
          runtime_health: runtime_health_payload()
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name(), map()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator, params \\ %{}) do
    request =
      case Map.get(params, "issue_id") do
        issue_id when is_binary(issue_id) and issue_id != "" ->
          Orchestrator.request_review_check(orchestrator, issue_id)

        _ ->
          Orchestrator.request_refresh(orchestrator)
      end

    case request do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      project: Map.get(entry, :project_label),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      project: Map.get(entry, :project_label),
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp pending_slot_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: entry.title,
      state: entry.state,
      priority: Map.get(entry, :priority),
      project: Map.get(entry, :project_label),
      url: Map.get(entry, :url),
      reason: Map.get(entry, :reason)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      project: Map.get(running, :project_label),
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      project: Map.get(retry, :project_label),
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp managed_project_payloads do
    Config.tracker_projects()
    |> Enum.map(fn project ->
      %{
        name: project.name,
        slug: project.slug,
        source: project.source
      }
    end)
  end

  defp runtime_health_payload do
    runtime_app_path = File.cwd!() |> Path.expand()
    runtime_repo_path = runtime_repo_path(runtime_app_path)
    control_dir = Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
    resume_state_dir = Store.state_dir() |> Path.expand()

    %{
      process: %{
        os_pid: System.pid(),
        node: node() |> Atom.to_string(),
        alive: true
      },
      runtime_app_path: runtime_app_path,
      runtime_repo_path: runtime_repo_path,
      runtime_git_commit: git_commit(runtime_repo_path),
      control_dir: control_dir,
      control_git_commit: git_commit(control_dir),
      workflow_path: Workflow.workflow_file_path() |> Path.expand(),
      deploy_intent_path: DeployIntent.path() |> Path.expand(),
      resume_state_dir: resume_state_dir,
      resume_state_access: resume_state_access(resume_state_dir)
    }
  end

  defp runtime_repo_path(runtime_app_path) do
    case System.get_env("SYMPHONY_REPO_DIR") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.expand("..", runtime_app_path)
    end
  end

  defp git_commit(path) when is_binary(path) do
    if File.dir?(Path.join(path, ".git")) do
      case System.cmd("git", ["rev-parse", "HEAD"], cd: path, stderr_to_stdout: true) do
        {commit, 0} -> String.trim(commit)
        _ -> nil
      end
    end
  rescue
    _error -> nil
  end

  defp resume_state_access(path) do
    probe_path = Path.join(path, ".symphony-health-probe-#{System.unique_integer([:positive])}")

    result =
      with :ok <- File.mkdir_p(path),
           :ok <- File.write(probe_path, "ok"),
           {:ok, "ok"} <- File.read(probe_path) do
        %{ok: true, checked_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
      else
        {:error, reason} ->
          %{ok: false, error: inspect(reason, limit: 5)}

        other ->
          %{ok: false, error: inspect(other, limit: 5)}
      end

    File.rm(probe_path)
    result
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp rate_limit_summary(rate_limits) when is_map(rate_limits) do
    buckets =
      [
        bucket_summary(:primary, map_value(rate_limits, ["primary", :primary])),
        bucket_summary(:secondary, map_value(rate_limits, ["secondary", :secondary]))
      ]
      |> Enum.reject(&is_nil/1)

    session = Enum.find(buckets, &(&1.kind == :session)) || Enum.find(buckets, &(&1.source == :primary))
    weekly = Enum.find(buckets, &(&1.kind == :weekly)) || Enum.find(buckets, &(&1.source == :secondary))

    %{
      session_remaining_percent: session && session.remaining_percent,
      weekly_remaining_percent: weekly && weekly.remaining_percent,
      session_reset: session && session.reset,
      weekly_reset: weekly && weekly.reset
    }
  end

  defp rate_limit_summary(_rate_limits) do
    %{
      session_remaining_percent: nil,
      weekly_remaining_percent: nil,
      session_reset: nil,
      weekly_reset: nil
    }
  end

  defp bucket_summary(source, bucket) when is_map(bucket) do
    window_mins = map_value(bucket, ["windowDurationMins", :windowDurationMins, "window_duration_mins", :window_duration_mins])

    %{
      source: source,
      kind: rate_limit_kind(source, bucket, window_mins),
      remaining_percent: remaining_percent(bucket),
      reset: map_value(bucket, ["resetAt", :resetAt, "reset_at", :reset_at, "resetsAt", :resetsAt, "resets_at", :resets_at])
    }
  end

  defp bucket_summary(_source, _bucket), do: nil

  defp rate_limit_kind(_source, bucket, window_mins) do
    name =
      bucket
      |> map_value(["name", :name, "limit_id", :limit_id, "limit_name", :limit_name])
      |> to_string()
      |> String.downcase()

    cond do
      String.contains?(name, "week") -> :weekly
      is_number(window_mins) and window_mins >= 7 * 24 * 60 -> :weekly
      true -> :session
    end
  end

  defp remaining_percent(bucket) when is_map(bucket) do
    used_percent = number_value(map_value(bucket, ["usedPercent", :usedPercent, "used_percent", :used_percent]))
    remaining_percent = number_value(map_value(bucket, ["remainingPercent", :remainingPercent, "remaining_percent", :remaining_percent]))
    remaining = number_value(map_value(bucket, ["remaining", :remaining]))
    limit = number_value(map_value(bucket, ["limit", :limit]))

    cond do
      is_number(remaining_percent) ->
        clamp_percent(remaining_percent)

      is_number(used_percent) ->
        clamp_percent(100 - used_percent)

      is_number(remaining) and is_number(limit) and limit > 0 ->
        clamp_percent(remaining / limit * 100)

      true ->
        nil
    end
  end

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_value(_map, _keys), do: nil

  defp number_value(value) when is_number(value), do: value

  defp number_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number_value(_value), do: nil

  defp clamp_percent(value) when is_number(value), do: value |> max(0) |> min(100)
  defp clamp_percent(_value), do: nil
end
