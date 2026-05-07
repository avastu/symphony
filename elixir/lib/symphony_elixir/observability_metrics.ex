defmodule SymphonyElixir.ObservabilityMetrics do
  @moduledoc """
  Durable aggregate metrics for the observability dashboard.
  """

  require Logger

  alias SymphonyElixir.DeployIntent
  alias SymphonyElixir.Linear.Issue

  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @type totals :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          seconds_running: non_neg_integer() | float()
        }

  @type snapshot :: %{
          codex_totals: totals(),
          completed_issues: map(),
          completed_count: non_neg_integer(),
          updated_at: String.t() | nil
        }

  @spec snapshot() :: snapshot()
  def snapshot do
    load()
  end

  @spec codex_totals() :: totals()
  def codex_totals do
    snapshot().codex_totals
  end

  @spec completed_count() :: non_neg_integer()
  def completed_count do
    snapshot().completed_count
  end

  @spec record_token_delta(map()) :: :ok
  def record_token_delta(%{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta)
      when is_integer(input) and is_integer(output) and is_integer(total) do
    update(fn metrics ->
      %{metrics | codex_totals: apply_token_delta(metrics.codex_totals, token_delta)}
    end)
  end

  def record_token_delta(_token_delta), do: :ok

  @spec record_session_completion(map()) :: :ok
  def record_session_completion(%{started_at: %DateTime{} = started_at}) do
    seconds_running = running_seconds(started_at, DateTime.utc_now())

    update(fn metrics ->
      %{
        metrics
        | codex_totals:
            apply_token_delta(metrics.codex_totals, %{
              input_tokens: 0,
              output_tokens: 0,
              total_tokens: 0,
              seconds_running: seconds_running
            })
      }
    end)
  end

  def record_session_completion(_running_entry), do: :ok

  @spec record_completed_issue(String.t(), map()) :: :ok
  def record_completed_issue(issue_id, running_entry) when is_binary(issue_id) and is_map(running_entry) do
    completed_at = timestamp()

    update(fn metrics ->
      completed_issues =
        Map.put_new(metrics.completed_issues, issue_id, %{
          "issue_id" => issue_id,
          "issue_identifier" => Map.get(running_entry, :identifier),
          "state" => running_entry |> Map.get(:issue) |> issue_state(),
          "project" => running_entry |> Map.get(:issue) |> Issue.project_label(),
          "session_id" => Map.get(running_entry, :session_id),
          "completed_at" => completed_at
        })

      %{metrics | completed_issues: completed_issues}
    end)
  end

  def record_completed_issue(_issue_id, _running_entry), do: :ok

  @spec path() :: Path.t()
  def path do
    Application.get_env(:symphony_elixir, :observability_metrics_file) ||
      System.get_env("SYMPHONY_OBSERVABILITY_METRICS_FILE") ||
      Path.join(Path.dirname(DeployIntent.path()), "observability-metrics.json")
  end

  @spec empty() :: snapshot()
  def empty do
    %{
      codex_totals: @empty_codex_totals,
      completed_issues: %{},
      completed_count: 0,
      updated_at: nil
    }
  end

  defp update(update_fun) when is_function(update_fun, 1) do
    metrics =
      load()
      |> update_fun.()
      |> normalize()
      |> Map.put(:updated_at, timestamp())

    case write(metrics) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist observability metrics: path=#{path()} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp load do
    metrics_path = path()

    if File.regular?(metrics_path) do
      case File.read(metrics_path) do
        {:ok, body} -> decode(body)
        {:error, reason} -> log_load_error(metrics_path, reason)
      end
    else
      empty()
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> normalize(decoded)
      {:ok, _decoded} -> empty()
      {:error, reason} -> log_load_error(path(), reason)
    end
  end

  defp log_load_error(metrics_path, reason) do
    Logger.warning("Failed to load observability metrics: path=#{metrics_path} reason=#{inspect(reason)}")
    empty()
  end

  defp write(metrics) do
    metrics_path = path()
    tmp_path = "#{metrics_path}.tmp-#{System.unique_integer([:positive])}"

    with {:ok, encoded} <- Jason.encode_to_iodata(encode(metrics)),
         :ok <- File.mkdir_p(Path.dirname(metrics_path)),
         :ok <- File.write(tmp_path, encoded),
         :ok <- File.rename(tmp_path, metrics_path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp_path)
        error
    end
  end

  defp normalize(metrics) when is_map(metrics) do
    completed_issues = map_value(metrics, :completed_issues, "completed_issues", %{})

    %{
      codex_totals:
        metrics
        |> map_value(:codex_totals, "codex_totals", @empty_codex_totals)
        |> normalize_totals(),
      completed_issues: normalize_completed_issues(completed_issues),
      completed_count: map_size(normalize_completed_issues(completed_issues)),
      updated_at: map_value(metrics, :updated_at, "updated_at", nil)
    }
  end

  defp encode(metrics) do
    %{
      "codex_totals" => metrics.codex_totals,
      "completed_issues" => metrics.completed_issues,
      "completed_count" => metrics.completed_count,
      "updated_at" => metrics.updated_at
    }
  end

  defp normalize_totals(totals) when is_map(totals) do
    %{
      input_tokens: non_negative_number(totals, :input_tokens, "input_tokens"),
      output_tokens: non_negative_number(totals, :output_tokens, "output_tokens"),
      total_tokens: non_negative_number(totals, :total_tokens, "total_tokens"),
      seconds_running: non_negative_number(totals, :seconds_running, "seconds_running")
    }
  end

  defp normalize_totals(_totals), do: @empty_codex_totals

  defp normalize_completed_issues(completed_issues) when is_map(completed_issues), do: completed_issues
  defp normalize_completed_issues(_completed_issues), do: %{}

  defp apply_token_delta(codex_totals, token_delta) do
    codex_totals = normalize_totals(codex_totals)

    %{
      input_tokens: max(0, codex_totals.input_tokens + Map.get(token_delta, :input_tokens, 0)),
      output_tokens: max(0, codex_totals.output_tokens + Map.get(token_delta, :output_tokens, 0)),
      total_tokens: max(0, codex_totals.total_tokens + Map.get(token_delta, :total_tokens, 0)),
      seconds_running: max(0, codex_totals.seconds_running + Map.get(token_delta, :seconds_running, 0))
    }
  end

  defp map_value(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end

  defp non_negative_number(map, atom_key, string_key) do
    value = map_value(map, atom_key, string_key, 0)

    if is_number(value), do: max(0, value), else: 0
  end

  defp issue_state(%Issue{state: state}), do: state
  defp issue_state(_issue), do: nil

  defp running_seconds(started_at, now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
