defmodule SymphonyElixir.DeployIntent do
  @moduledoc """
  File-backed deploy-pending intent shared with Symphony control scripts.
  """

  alias SymphonyElixir.Workflow

  @blocking_statuses MapSet.new(["pending", "draining", "deploying", "failed"])
  @redeploy_targets %{
    "control" => "redeploy-symphony-control",
    "runtime" => "redeploy-symphony"
  }

  @spec load() :: map() | nil
  def load do
    path = path()

    if File.regular?(path) do
      case File.read(path) do
        {:ok, body} -> decode(path, body)
        {:error, reason} -> failed_intent("deploy intent file could not be read: #{path} #{inspect(reason)}")
      end
    else
      nil
    end
  end

  @spec path() :: Path.t()
  def path do
    Application.get_env(:symphony_elixir, :deploy_intent_file) ||
      System.get_env("SYMPHONY_DEPLOY_INTENT_FILE") ||
      Path.join([control_dir(), "log", "deploy-intent.json"])
  end

  @spec active?(map() | nil) :: boolean()
  def active?(%{"status" => status}) when is_binary(status),
    do: MapSet.member?(@blocking_statuses, normalize_status(status))

  def active?(_intent), do: false

  @spec failed?(map() | nil) :: boolean()
  def failed?(%{"status" => status}) when is_binary(status), do: normalize_status(status) == "failed"
  def failed?(_intent), do: false

  @spec deploying?(map() | nil) :: boolean()
  def deploying?(%{"status" => status}) when is_binary(status), do: normalize_status(status) == "deploying"
  def deploying?(_intent), do: false

  @spec target_command(map()) :: {:ok, String.t()} | {:error, String.t()}
  def target_command(%{"target" => target}) when is_binary(target) do
    case Map.fetch(@redeploy_targets, normalize_target(target)) do
      {:ok, script} -> {:ok, Path.join([control_dir(), "scripts", script])}
      :error -> {:error, "unsupported deploy target #{inspect(target)}"}
    end
  end

  def target_command(_intent), do: {:error, "deploy intent missing target"}

  @spec write_draining(map(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def write_draining(intent, running_count, retrying_count) do
    intent
    |> Map.merge(%{
      "status" => "draining",
      "running_count" => running_count,
      "retrying_count" => retrying_count,
      "updated_at" => timestamp()
    })
    |> write()
  end

  @spec write_deploying(map()) :: :ok | {:error, term()}
  def write_deploying(intent) do
    intent
    |> Map.merge(%{
      "status" => "deploying",
      "running_count" => 0,
      "retrying_count" => 0,
      "blocker" => nil,
      "deploy_started_at" => timestamp(),
      "updated_at" => timestamp()
    })
    |> write()
  end

  @spec write_failed(map(), String.t()) :: :ok | {:error, term()}
  def write_failed(intent, blocker) when is_binary(blocker) do
    intent
    |> Map.merge(%{
      "status" => "failed",
      "blocker" => blocker,
      "updated_at" => timestamp()
    })
    |> write()
  end

  @spec write(map()) :: :ok | {:error, term()}
  def write(intent) when is_map(intent) do
    target_path = path()
    tmp_path = "#{target_path}.tmp-#{System.unique_integer([:positive])}"

    with {:ok, encoded} <- Jason.encode_to_iodata(intent),
         :ok <- File.mkdir_p(Path.dirname(target_path)),
         :ok <- File.write(tmp_path, encoded),
         :ok <- File.rename(tmp_path, target_path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp_path)
        error
    end
  end

  @spec summary(map() | nil) :: String.t() | nil
  def summary(nil), do: nil

  def summary(intent) when is_map(intent) do
    target = Map.get(intent, "target", "unknown")
    status = Map.get(intent, "status", "unknown")
    running = Map.get(intent, "running_count", 0)
    retrying = Map.get(intent, "retrying_count", 0)

    base = "Deploy pending: #{status} #{running} running / #{retrying} retrying target=#{target}"

    case Map.get(intent, "blocker") do
      blocker when is_binary(blocker) and blocker != "" -> "#{base} blocker=#{blocker}"
      _ -> base
    end
  end

  @spec public_payload(map() | nil) :: map() | nil
  def public_payload(nil), do: nil

  def public_payload(intent) when is_map(intent) do
    %{
      active: active?(intent),
      target: Map.get(intent, "target"),
      status: Map.get(intent, "status"),
      requested_at: Map.get(intent, "requested_at"),
      requested_by: Map.get(intent, "requested_by"),
      requested_revision: Map.get(intent, "requested_revision"),
      requested_branch: Map.get(intent, "requested_branch"),
      running_count: Map.get(intent, "running_count", 0),
      retrying_count: Map.get(intent, "retrying_count", 0),
      blocker: Map.get(intent, "blocker"),
      updated_at: Map.get(intent, "updated_at"),
      summary: summary(intent)
    }
  end

  defp normalize(intent) do
    intent
    |> stringify_keys()
    |> Map.update("status", "pending", &normalize_status/1)
    |> Map.update("target", "control", &normalize_target/1)
  end

  defp decode(path, body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        normalize(decoded)

      {:ok, _decoded} ->
        failed_intent("deploy intent file must contain a JSON object: #{path}")

      {:error, _reason} ->
        failed_intent("deploy intent file is not valid JSON: #{path}")
    end
  end

  defp failed_intent(blocker) do
    %{
      "status" => "failed",
      "target" => "unknown",
      "blocker" => blocker,
      "updated_at" => timestamp()
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_status(status), do: status |> to_string() |> String.trim() |> String.downcase()
  defp normalize_target(target), do: target |> to_string() |> String.trim() |> String.downcase()

  defp control_dir do
    System.get_env("SYMPHONY_CONTROL_DIR") ||
      [
        Path.expand("../../symphony-control", File.cwd!()),
        Path.expand("../../SymphonyControl", File.cwd!()),
        Path.expand("../SymphonyControl", File.cwd!()),
        Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
      ]
      |> Enum.find(&File.dir?/1)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
