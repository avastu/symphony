defmodule SymphonyElixir.DeployIntentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DeployIntent

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-deploy-intent-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    intent_file = Path.join(dir, "deploy-intent.json")
    Application.put_env(:symphony_elixir, :deploy_intent_file, intent_file)

    on_exit(fn ->
      File.rm_rf(dir)
    end)

    {:ok, intent_file: intent_file}
  end

  test "deploy-pending suppresses dispatch while running work drains", %{intent_file: intent_file} do
    write_intent!(%{"target" => "control", "status" => "pending"})
    parent = self()

    Application.put_env(:symphony_elixir, :deploy_command_runner, fn _command, _intent_file ->
      send(parent, :deploy_started)
    end)

    running_issue = issue("issue-running", "UTS-1", "In Progress")

    state = %Orchestrator.State{
      running: %{
        running_issue.id => %{
          pid: self(),
          ref: make_ref(),
          identifier: running_issue.identifier,
          issue: running_issue,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([running_issue.id])
    }

    updated = Orchestrator.handle_deploy_intent_for_test(state, DeployIntent.load())
    intent = Jason.decode!(File.read!(intent_file))

    assert Map.has_key?(updated.running, running_issue.id)
    assert intent["status"] == "draining"
    assert intent["running_count"] == 1
    assert intent["retrying_count"] == 0
    refute_received :deploy_started
  end

  test "poll cycle keeps intake closed while deploy-pending is active", %{intent_file: intent_file} do
    write_intent!(%{"target" => "control", "status" => "pending"})
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 2)

    running_issue = issue("issue-running", "UTS-1", "In Progress")
    candidate_issue = issue("issue-candidate", "UTS-2", "Todo")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [running_issue, candidate_issue])

    state = %Orchestrator.State{
      running: %{
        running_issue.id => %{
          pid: self(),
          ref: nil,
          identifier: running_issue.identifier,
          issue: running_issue,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([running_issue.id]),
      max_concurrent_agents: 2
    }

    updated = Orchestrator.poll_once_for_test(state)
    intent = Jason.decode!(File.read!(intent_file))

    assert Map.keys(updated.running) == [running_issue.id]
    assert updated.claimed == MapSet.new([running_issue.id])
    refute Map.has_key?(updated.running, candidate_issue.id)
    refute MapSet.member?(updated.claimed, candidate_issue.id)
    assert intent["status"] == "draining"
    assert intent["running_count"] == 1
    assert intent["retrying_count"] == 0
  end

  test "targeted review check does not dispatch while deploy-pending is active" do
    write_intent!(%{"target" => "control", "status" => "draining", "running_count" => 1})

    state = %Orchestrator.State{
      claimed: MapSet.new(["issue-review-check"]),
      max_concurrent_agents: 1
    }

    assert {:reply, payload, updated} =
             Orchestrator.handle_call(
               {:request_review_check, "issue-review-check"},
               {self(), make_ref()},
               state
             )

    assert payload.queued == false
    assert payload.reason == "deploy_pending"
    assert payload.operations == ["review_check"]
    assert payload.deploy_pending.active == true
    refute MapSet.member?(updated.claimed, "issue-review-check")
    assert updated.running == %{}
  end

  test "retry timer releases claim without dispatch while deploy-pending is active" do
    write_intent!(%{"target" => "control", "status" => "draining", "running_count" => 0, "retrying_count" => 1})

    retry_token = make_ref()
    retry_timer = Process.send_after(self(), :retry_marker, 60_000)

    state = %Orchestrator.State{
      claimed: MapSet.new(["issue-retry"]),
      retry_attempts: %{
        "issue-retry" => %{
          attempt: 1,
          timer_ref: retry_timer,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 60_000,
          identifier: "UTS-RETRY"
        }
      }
    }

    assert {:noreply, updated} = Orchestrator.handle_info({:retry_issue, "issue-retry", retry_token}, state)
    refute MapSet.member?(updated.claimed, "issue-retry")
    assert updated.retry_attempts == %{}
    assert updated.running == %{}
  end

  test "deploy-pending does not restart stalled running work while draining" do
    write_intent!(%{"target" => "control", "status" => "pending"})
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", codex_stall_timeout_ms: 1_000)

    running_issue = issue("issue-stall", "UTS-STALL", "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [running_issue])

    worker_pid =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)

    state = %Orchestrator.State{
      running: %{
        running_issue.id => %{
          pid: worker_pid,
          ref: nil,
          identifier: running_issue.identifier,
          issue: running_issue,
          last_codex_timestamp: stale_activity_at,
          started_at: stale_activity_at
        }
      },
      claimed: MapSet.new([running_issue.id])
    }

    updated = Orchestrator.poll_once_for_test(state)
    intent = Jason.decode!(File.read!(DeployIntent.path()))

    assert Process.alive?(worker_pid)
    assert Map.has_key?(updated.running, running_issue.id)
    assert updated.retry_attempts == %{}
    assert intent["status"] == "draining"
    assert intent["running_count"] == 1

    Process.exit(worker_pid, :kill)
  end

  test "deploy-pending pauses retry queue before a later zero-count redeploy", %{intent_file: intent_file} do
    write_intent!(%{"target" => "runtime", "status" => "pending"})
    parent = self()

    Application.put_env(:symphony_elixir, :deploy_command_runner, fn command, path ->
      send(parent, {:deploy_started, command, path})
      :ok
    end)

    retry_timer = Process.send_after(self(), :retry_marker, 60_000)

    state = %Orchestrator.State{
      claimed: MapSet.new(["issue-retry"]),
      retry_attempts: %{
        "issue-retry" => %{
          attempt: 2,
          timer_ref: retry_timer,
          retry_token: make_ref(),
          due_at_ms: System.monotonic_time(:millisecond) + 60_000,
          identifier: "UTS-2"
        }
      }
    }

    updated = Orchestrator.handle_deploy_intent_for_test(state, DeployIntent.load())
    intent = Jason.decode!(File.read!(intent_file))

    assert updated.retry_attempts == %{}
    refute MapSet.member?(updated.claimed, "issue-retry")
    assert intent["status"] == "draining"
    refute_received {:deploy_started, _command, _path}

    _updated = Orchestrator.handle_deploy_intent_for_test(updated, DeployIntent.load())
    intent = Jason.decode!(File.read!(intent_file))

    assert intent["status"] == "deploying"
    assert_receive {:deploy_started, command, ^intent_file}
    assert String.ends_with?(command, "redeploy-symphony")
  end

  test "deploying deploy-pending intent does not launch another redeploy", %{intent_file: intent_file} do
    write_intent!(%{"target" => "control", "status" => "deploying"})
    parent = self()

    Application.put_env(:symphony_elixir, :deploy_command_runner, fn command, path ->
      send(parent, {:deploy_started, command, path})
      :ok
    end)

    _updated = Orchestrator.handle_deploy_intent_for_test(%Orchestrator.State{}, DeployIntent.load())

    refute_received {:deploy_started, _command, _path}
    assert Jason.decode!(File.read!(intent_file))["status"] == "deploying"
  end

  test "failed deploy-pending intent remains blocking across poll cycles", %{intent_file: intent_file} do
    write_intent!(%{"target" => "control", "status" => "failed", "blocker" => "health failed"})
    parent = self()

    Application.put_env(:symphony_elixir, :deploy_command_runner, fn command, path ->
      send(parent, {:deploy_started, command, path})
      :ok
    end)

    _updated = Orchestrator.handle_deploy_intent_for_test(%Orchestrator.State{}, DeployIntent.load())
    intent = Jason.decode!(File.read!(intent_file))

    assert intent["status"] == "failed"
    assert intent["blocker"] == "health failed"
    refute_received {:deploy_started, _command, _path}
  end

  test "zero running and retrying starts redeploy without allow-active and preserves failed blocker", %{intent_file: intent_file} do
    write_intent!(%{"target" => "control", "status" => "pending"})

    Application.put_env(:symphony_elixir, :deploy_command_runner, fn _command, _intent_file ->
      {:error, "build failed: mix compile"}
    end)

    state = Orchestrator.handle_deploy_intent_for_test(%Orchestrator.State{}, DeployIntent.load())
    intent = Jason.decode!(File.read!(intent_file))

    assert state.running == %{}
    assert intent["status"] == "failed"
    assert intent["blocker"] == "build failed: mix compile"
  end

  test "corrupt deploy intent file fails closed", %{intent_file: intent_file} do
    File.write!(intent_file, "{not json")

    intent = DeployIntent.load()

    assert DeployIntent.active?(intent)
    assert DeployIntent.failed?(intent)
    assert intent["target"] == "unknown"
    assert intent["blocker"] =~ "not valid JSON"
  end

  test "public payload and dashboard status expose deploy-pending state" do
    write_intent!(%{
      "target" => "control",
      "status" => "draining",
      "running_count" => 1,
      "retrying_count" => 0,
      "requested_by" => "test"
    })

    payload = DeployIntent.public_payload(DeployIntent.load())
    assert payload.active == true
    assert payload.summary =~ "Deploy pending: draining 1 running / 0 retrying target=control"

    content =
      StatusDashboard.format_snapshot_content_for_test(
        {:ok,
         %{
           running: [],
           retrying: [],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           deploy_pending: payload
         }},
        0
      )

    assert content =~ "Deploy pending: draining 1 running / 0 retrying target=control"
  end

  defp write_intent!(intent) do
    intent
    |> Map.put_new("requested_at", DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put_new("requested_by", "test")
    |> Map.put_new("running_count", 0)
    |> Map.put_new("retrying_count", 0)
    |> DeployIntent.write()
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Deploy test",
      description: "Deploy test",
      state: state,
      url: "https://example.test/#{identifier}"
    }
  end
end
