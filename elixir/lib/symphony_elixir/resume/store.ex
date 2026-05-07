defmodule SymphonyElixir.Resume.Store do
  @moduledoc """
  File-backed durable resume state.

  The store intentionally persists only coordination metadata and sanitized
  summaries. It uses atomic JSON replacement for each record and short-lived
  lock files for scheduler/resume decisions.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}
  alias SymphonyElixir.Resume.Sanitizer

  @open_lease_statuses MapSet.new(["active", "heartbeat", "running", "starting"])
  @blocked_resume_statuses MapSet.new(["blocked", "failed", "needs_review"])

  @type record :: map()
  @type store_result :: {:ok, record()} | {:error, term()}

  @spec create_run_and_lease(Issue.t(), keyword()) :: {:ok, %{run: record(), lease: record()}} | {:error, term()}
  def create_run_and_lease(%Issue{} = issue, opts \\ []) do
    now = timestamp()
    run_id = Keyword.get(opts, :run_id) || unique_id("run")
    lease_id = Keyword.get(opts, :lease_id) || unique_id("lease")
    worker_host = Keyword.get(opts, :worker_host)
    ttl_ms = Keyword.get(opts, :ttl_ms, Config.settings!().resume.lease_ttl_ms)
    attempt = Keyword.get(opts, :attempt, 0)
    session_key = session_key(issue, Keyword.get(opts, :session_key))

    run = %{
      record_type: "IssueRun",
      run_id: run_id,
      issue_id: issue.id,
      identifier: issue.identifier,
      session_key: session_key,
      title: issue.title,
      linear_state: issue.state,
      workpad_state: issue.workpad_state,
      workpad_phase: issue.workpad_phase,
      project: Issue.project_label(issue),
      workspace_path: Keyword.get(opts, :workspace_path),
      worker_host: worker_host,
      lifecycle_state: "running",
      attempt: attempt,
      latest_checkpoint_id: nil,
      lease_id: lease_id,
      resume_packet_status: nil,
      created_at: now,
      updated_at: now
    }

    lease = %{
      record_type: "RunnerLease",
      lease_id: lease_id,
      run_id: run_id,
      issue_id: issue.id,
      identifier: issue.identifier,
      session_key: session_key,
      worker_host: worker_host,
      owner_instance_id: owner_instance_id(),
      status: "active",
      started_at: now,
      heartbeat_at: now,
      expires_at: expires_at(ttl_ms)
    }

    with {:ok, persisted_run} <- put_issue_run(run),
         {:ok, persisted_lease} <- put_runner_lease(lease) do
      {:ok, %{run: persisted_run, lease: persisted_lease}}
    end
  end

  @spec put_issue_run(map()) :: store_result()
  def put_issue_run(attrs) when is_map(attrs) do
    record =
      attrs
      |> Map.put_new(:record_type, "IssueRun")
      |> Map.put_new(:run_id, unique_id("run"))
      |> put_updated_at()

    write_record(run_path(record), record)
  end

  @spec update_issue_run(String.t(), String.t(), map()) :: store_result()
  def update_issue_run(issue_id, run_id, attrs) when is_binary(issue_id) and is_binary(run_id) and is_map(attrs) do
    path = run_path(%{issue_id: issue_id, run_id: run_id})

    record =
      path
      |> read_json_file()
      |> case do
        {:ok, existing} -> Map.merge(existing, stringify_keys(attrs))
        {:error, _reason} -> attrs |> Map.put(:issue_id, issue_id) |> Map.put(:run_id, run_id)
      end
      |> Map.put("record_type", "IssueRun")
      |> put_updated_at()

    write_record(path, record)
  end

  @spec put_runner_lease(map()) :: store_result()
  def put_runner_lease(attrs) when is_map(attrs) do
    record =
      attrs
      |> Map.put_new(:record_type, "RunnerLease")
      |> Map.put_new(:lease_id, unique_id("lease"))
      |> put_updated_at()

    write_record(lease_path(record), record)
  end

  @spec heartbeat_runner_lease(String.t(), map()) :: store_result()
  def heartbeat_runner_lease(lease_id, attrs \\ %{}) when is_binary(lease_id) and is_map(attrs) do
    path = lease_path(%{lease_id: lease_id})
    ttl_ms = Config.settings!().resume.lease_ttl_ms

    case read_json_file(path) do
      {:ok, existing} ->
        record =
          existing
          |> Map.merge(stringify_keys(attrs))
          |> Map.merge(%{
            "record_type" => "RunnerLease",
            "lease_id" => lease_id,
            "status" => "heartbeat",
            "heartbeat_at" => timestamp(),
            "expires_at" => expires_at(ttl_ms)
          })
          |> put_updated_at()

        write_record(path, record)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec close_runner_lease(String.t(), String.t(), map()) :: store_result()
  def close_runner_lease(lease_id, status, attrs \\ %{})
      when is_binary(lease_id) and is_binary(status) and is_map(attrs) do
    path = lease_path(%{lease_id: lease_id})

    case read_json_file(path) do
      {:ok, existing} ->
        record =
          existing
          |> Map.merge(stringify_keys(attrs))
          |> Map.merge(%{
            "record_type" => "RunnerLease",
            "lease_id" => lease_id,
            "status" => status,
            "closed_at" => timestamp()
          })
          |> put_updated_at()

        write_record(path, record)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec put_workspace_checkpoint(map()) :: store_result()
  def put_workspace_checkpoint(attrs) when is_map(attrs) do
    record =
      attrs
      |> Map.put_new(:record_type, "WorkspaceCheckpoint")
      |> Map.put_new(:checkpoint_id, unique_id("checkpoint"))
      |> put_updated_at()

    write_record(checkpoint_path(record), record)
  end

  @spec write_resume_packet(map()) :: store_result()
  def write_resume_packet(attrs) when is_map(attrs) do
    record =
      attrs
      |> Map.put_new(:record_type, "ResumePacket")
      |> Map.put_new(:packet_id, unique_id("resume"))
      |> Map.put_new(:status, "blocked")
      |> put_updated_at()

    write_record(resume_packet_path(record), record)
  end

  @spec latest_workspace_checkpoint(String.t()) :: record() | nil
  def latest_workspace_checkpoint(issue_id) when is_binary(issue_id) do
    issue_id
    |> checkpoint_glob()
    |> Path.wildcard()
    |> read_records()
    |> Enum.sort_by(&Map.get(&1, "updated_at", ""), :desc)
    |> List.first()
  end

  @spec list_runner_leases() :: [record()]
  def list_runner_leases do
    "leases"
    |> record_glob()
    |> Path.wildcard()
    |> read_records()
  end

  @spec list_issue_runs() :: [record()]
  def list_issue_runs do
    "runs"
    |> record_glob()
    |> Path.wildcard()
    |> read_records()
  end

  @spec list_resume_packets() :: [record()]
  def list_resume_packets do
    "resume_packets"
    |> record_glob()
    |> Path.wildcard()
    |> read_records()
  end

  @spec open_lease_for_issue?(String.t()) :: boolean()
  def open_lease_for_issue?(issue_id) when is_binary(issue_id) do
    Enum.any?(list_runner_leases(), fn lease ->
      Map.get(lease, "issue_id") == issue_id and open_lease?(lease)
    end)
  end

  @spec active_lease_for_issue?(String.t()) :: boolean()
  def active_lease_for_issue?(issue_id) when is_binary(issue_id) do
    now = DateTime.utc_now()

    Enum.any?(list_runner_leases(), fn lease ->
      Map.get(lease, "issue_id") == issue_id and open_lease?(lease) and not lease_expired?(lease, now)
    end)
  end

  @spec blocked_resume_packet_for_issue?(String.t()) :: boolean()
  def blocked_resume_packet_for_issue?(issue_id) when is_binary(issue_id) do
    Enum.any?(list_resume_packets(), fn packet ->
      Map.get(packet, "issue_id") == issue_id and MapSet.member?(@blocked_resume_statuses, Map.get(packet, "status"))
    end)
  end

  @spec expire_stale_leases() :: {:ok, [record()]}
  def expire_stale_leases do
    now = DateTime.utc_now()

    expired =
      list_runner_leases()
      |> Enum.flat_map(&expire_stale_lease(&1, now))

    {:ok, expired}
  end

  @spec acquire_scheduler_lock(non_neg_integer(), map()) :: {:ok, record()} | {:error, :locked | term()}
  def acquire_scheduler_lock(ttl_ms, attrs \\ %{}) when is_integer(ttl_ms) and ttl_ms > 0 and is_map(attrs) do
    acquire_lock("scheduler", ttl_ms, attrs)
  end

  @spec release_scheduler_lock(map()) :: :ok
  def release_scheduler_lock(%{"lock_name" => lock_name}), do: release_lock(lock_name)
  def release_scheduler_lock(%{lock_name: lock_name}), do: release_lock(lock_name)
  def release_scheduler_lock(_lock), do: :ok

  @spec with_scheduler_lock(non_neg_integer(), map(), (record() -> term())) ::
          {:ok, term()} | {:error, :locked | term()}
  def with_scheduler_lock(ttl_ms, attrs, fun)
      when is_integer(ttl_ms) and ttl_ms > 0 and is_map(attrs) and is_function(fun, 1) do
    case acquire_scheduler_lock(ttl_ms, attrs) do
      {:ok, lock} ->
        try do
          {:ok, fun.(lock)}
        after
          release_scheduler_lock(lock)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec state_dir() :: Path.t()
  def state_dir do
    Config.settings!().resume.state_dir
  end

  @spec open_lease?(map()) :: boolean()
  def open_lease?(lease) when is_map(lease) do
    status = Map.get(lease, "status") || Map.get(lease, :status)
    MapSet.member?(@open_lease_statuses, to_string(status || ""))
  end

  @spec lease_expired?(map(), DateTime.t()) :: boolean()
  def lease_expired?(lease, %DateTime{} = now) when is_map(lease) do
    lease
    |> Map.get("expires_at")
    |> parse_datetime()
    |> case do
      {:ok, expires_at} -> DateTime.compare(expires_at, now) != :gt
      :error -> true
    end
  end

  defp acquire_lock(lock_name, ttl_ms, attrs) do
    path = lock_path(lock_name)
    now = timestamp()

    lock =
      attrs
      |> Map.merge(%{
        lock_name: lock_name,
        owner_instance_id: owner_instance_id(),
        acquired_at: now,
        expires_at: expires_at(ttl_ms)
      })
      |> Sanitizer.sanitize()

    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          IO.write(io, Jason.encode!(lock, pretty: true))
          {:ok, lock}
        after
          File.close(io)
        end

      {:error, :eexist} ->
        if expired_lock?(path) do
          File.rm(path)
          acquire_lock(lock_name, ttl_ms, attrs)
        else
          {:error, :locked}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_lock(lock_name) when is_binary(lock_name) do
    lock_name
    |> lock_path()
    |> File.rm()
    |> case do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        log_store_error("release lock #{lock_name}", reason)
        :ok
    end
  end

  defp release_lock(_lock_name), do: :ok

  defp expired_lock?(path) do
    with {:ok, lock} <- read_json_file(path),
         {:ok, expires_at} <- parse_datetime(Map.get(lock, "expires_at")) do
      DateTime.compare(expires_at, DateTime.utc_now()) != :gt
    else
      _ -> true
    end
  end

  defp expire_stale_lease(lease, now) do
    if open_lease?(lease) and lease_expired?(lease, now) do
      close_expired_lease(lease)
    else
      []
    end
  end

  defp close_expired_lease(lease) do
    lease_id = Map.get(lease, "lease_id")

    case close_runner_lease(lease_id, "expired", %{expired_by: owner_instance_id()}) do
      {:ok, record} ->
        [record]

      {:error, reason} ->
        log_store_error("expire lease #{lease_id}", reason)
        []
    end
  end

  defp write_record(path, record) do
    sanitized =
      record
      |> stringify_keys()
      |> Sanitizer.sanitize()

    with :ok <- write_json_atomic(path, sanitized) do
      {:ok, sanitized}
    end
  end

  defp write_json_atomic(path, record) do
    File.mkdir_p!(Path.dirname(path))
    temp_path = path <> ".tmp-" <> unique_id("write")

    with {:ok, json} <- Jason.encode(record, pretty: true),
         :ok <- File.write(temp_path, json),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp_path)
        {:error, reason}
    end
  end

  defp read_json_file(path) do
    case File.read(path) do
      {:ok, body} -> Jason.decode(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_records(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(fn path ->
      case read_json_file(path) do
        {:ok, record} ->
          [record]

        {:error, reason} ->
          log_store_error("read #{path}", reason)
          []
      end
    end)
  end

  defp run_path(record) do
    issue_id = record[:issue_id] || record["issue_id"] || "unknown_issue"
    run_id = record[:run_id] || record["run_id"] || unique_id("run")
    Path.join([state_dir(), "runs", "#{safe_filename(issue_id)}__#{safe_filename(run_id)}.json"])
  end

  defp lease_path(record) do
    lease_id = record[:lease_id] || record["lease_id"] || unique_id("lease")
    Path.join([state_dir(), "leases", "#{safe_filename(lease_id)}.json"])
  end

  defp checkpoint_path(record) do
    issue_id = record[:issue_id] || record["issue_id"] || "unknown_issue"
    checkpoint_id = record[:checkpoint_id] || record["checkpoint_id"] || unique_id("checkpoint")

    Path.join([
      state_dir(),
      "checkpoints",
      safe_filename(issue_id),
      "#{safe_filename(checkpoint_id)}.json"
    ])
  end

  defp resume_packet_path(record) do
    issue_id = record[:issue_id] || record["issue_id"] || "unknown_issue"
    packet_id = record[:packet_id] || record["packet_id"] || unique_id("resume")

    Path.join([
      state_dir(),
      "resume_packets",
      "#{safe_filename(issue_id)}__#{safe_filename(packet_id)}.json"
    ])
  end

  defp lock_path(lock_name) do
    Path.join([state_dir(), "locks", "#{safe_filename(lock_name)}.json"])
  end

  defp checkpoint_glob(issue_id) do
    Path.join([state_dir(), "checkpoints", safe_filename(issue_id), "*.json"])
  end

  defp record_glob(kind) do
    Path.join([state_dir(), kind, "*.json"])
  end

  defp put_updated_at(record) do
    Map.put(record, record_key(record, :updated_at), timestamp())
  end

  defp record_key(record, key) do
    if Enum.any?(Map.keys(record), &is_binary/1), do: Atom.to_string(key), else: key
  end

  defp stringify_keys(%DateTime{} = value), do: value

  defp stringify_keys(%MapSet{} = value), do: value |> MapSet.to_list() |> stringify_keys()

  defp stringify_keys(%_struct{} = value), do: value

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp session_key(%Issue{id: issue_id}, nil), do: issue_id || unique_id("session")
  defp session_key(_issue, session_key) when is_binary(session_key), do: session_key
  defp session_key(_issue, _session_key), do: unique_id("session")

  defp safe_filename(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> String.slice(0, 160)
    |> case do
      "" -> "blank"
      safe -> safe
    end
  end

  defp unique_id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}_#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp expires_at(ttl_ms) do
    DateTime.utc_now()
    |> DateTime.add(ttl_ms, :millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp owner_instance_id do
    {:ok, host} = :inet.gethostname()
    hostname = to_string(host)

    "#{hostname}:#{System.pid()}"
  end

  defp log_store_error(operation, reason) do
    Logger.warning("Resume store failed to #{operation}: #{inspect(reason)}")
    :ok
  end
end
