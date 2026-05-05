defmodule SymphonyElixir.AttentionInbox do
  @moduledoc """
  Cached access to the operator attention inbox used by the observability UI.
  """

  use GenServer

  alias SymphonyElixirWeb.ObservabilityPubSub

  @classification_priority %{
    "needs_decision" => {20, "P2 Decide", "Decision needed."},
    "blocked" => {10, "P1 Blocker", "Blocked work needs intervention."},
    "ready_for_review" => {30, "P3 Review", "Ready for human review."},
    "unanswered_comment" => {35, "P3 Reply", "Unanswered comment needs a response."},
    "stale_wait" => {40, "P4 Stale", "Waiting state is stale."},
    "fyi" => {50, "P5 FYI", "Informational."}
  }
  @default_refresh_ms 60_000
  @default_command "/Users/utsav/dev/symphony-control/scripts/attention-inbox"
  @default_reply_command "/Users/utsav/dev/symphony-control/scripts/attention-reply"
  @url_pattern ~r/https?:\/\/[^\s<>"')\]]+/
  @trailing_url_punctuation ~r/[.,;:!?]+$/

  defstruct [
    :name,
    :refresh_timer_ref,
    :fetch_fun,
    :reply_fun,
    :refresh_ms,
    :auto_refresh,
    status: "loading",
    items: [],
    fetched_at: nil,
    expires_at: nil,
    error: nil,
    refreshing: false,
    last_action: nil
  ]

  @type snapshot :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot(GenServer.name(), timeout()) :: snapshot()
  def snapshot(server \\ __MODULE__, timeout \\ 1_000) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :snapshot, timeout)

      _ ->
        unavailable_snapshot()
    end
  catch
    :exit, _reason -> unavailable_snapshot()
  end

  @spec refresh(GenServer.name(), timeout()) :: {:ok, snapshot()} | {:error, term(), snapshot()}
  def refresh(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :refresh, timeout)
  end

  @spec approve(String.t(), keyword()) :: {:ok, snapshot()} | {:error, term(), snapshot()}
  def approve(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    act(Keyword.get(opts, :server, __MODULE__), issue_identifier, "approve", opts)
  end

  @spec deny(String.t(), keyword()) :: {:ok, snapshot()} | {:error, term(), snapshot()}
  def deny(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    act(Keyword.get(opts, :server, __MODULE__), issue_identifier, "deny", opts)
  end

  @spec act(GenServer.name(), String.t(), String.t() | atom(), keyword()) ::
          {:ok, snapshot()} | {:error, term(), snapshot()}
  def act(server, issue_identifier, action, opts \\ [])
      when is_binary(issue_identifier) and is_list(opts) do
    GenServer.call(server, {:act, issue_identifier, normalize_action(action), Keyword.get(opts, :note)}, 30_000)
  end

  @spec default_fetch() :: {:ok, String.t()} | {:error, term()}
  def default_fetch do
    command = System.get_env("SYMPHONY_ATTENTION_INBOX_COMMAND") || @default_command

    case System.cmd(command, ["--json"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, status, summarize_output(output)}}
    end
  rescue
    error -> {:error, {:command_error, Exception.message(error)}}
  end

  @spec default_reply(String.t(), String.t()) :: :ok | {:error, term()}
  def default_reply(issue_identifier, body)
      when is_binary(issue_identifier) and is_binary(body) do
    command = System.get_env("SYMPHONY_ATTENTION_REPLY_COMMAND") || @default_reply_command

    case System.cmd(command, ["--issue", issue_identifier, "--body", body, "--post"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:command_failed, status, summarize_output(output)}}
    end
  rescue
    error -> {:error, {:command_error, Exception.message(error)}}
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.get(opts, :name, __MODULE__),
      fetch_fun: Keyword.get(opts, :fetch_fun, configured_fetch_fun()),
      reply_fun: Keyword.get(opts, :reply_fun, configured_reply_fun()),
      refresh_ms: Keyword.get(opts, :refresh_ms, configured_refresh_ms()),
      auto_refresh: Keyword.get(opts, :auto_refresh, configured_auto_refresh())
    }

    state =
      if state.auto_refresh do
        schedule_refresh(state, 0)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call(:refresh, _from, state) do
    {reply, state} = refresh_state(%{state | refreshing: true})
    {:reply, reply, state}
  end

  def handle_call({:act, issue_identifier, action, note}, _from, state) do
    {reply, state} =
      if action in ["approve", "deny"] do
        body = action_body(action, note)

        case state.reply_fun.(issue_identifier, body) do
          :ok ->
            action_state = %{
              state
              | last_action: %{
                  issue_identifier: issue_identifier,
                  action: action,
                  posted_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
                },
                refreshing: true
            }

            refresh_state(action_state)

          {:error, reason} ->
            state = %{
              state
              | last_action: %{
                  issue_identifier: issue_identifier,
                  action: action,
                  error: format_reason(reason),
                  posted_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
                }
            }

            {{:error, reason, snapshot_from_state(state)}, state}
        end
      else
        reason = {:unsupported_attention_action, action}
        {{:error, reason, snapshot_from_state(state)}, state}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {_reply, state} = refresh_state(%{state | refreshing: true})
    {:noreply, schedule_refresh(state, state.refresh_ms)}
  end

  defp refresh_state(state) do
    case state.fetch_fun.() do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, items} when is_list(items) ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)

            state = %{
              state
              | status: "ready",
                items: normalize_items(items),
                fetched_at: DateTime.to_iso8601(now),
                expires_at: now |> DateTime.add(div(state.refresh_ms, 1_000), :second) |> DateTime.to_iso8601(),
                error: nil,
                refreshing: false
            }

            ObservabilityPubSub.broadcast_update()
            {{:ok, snapshot_from_state(state)}, state}

          {:ok, _other} ->
            refresh_error(state, :invalid_attention_payload)

          {:error, reason} ->
            refresh_error(state, {:invalid_json, reason})
        end

      {:error, reason} ->
        refresh_error(state, reason)
    end
  end

  defp refresh_error(state, reason) do
    state = %{state | status: "error", error: format_reason(reason), refreshing: false}
    ObservabilityPubSub.broadcast_update()
    {{:error, reason, snapshot_from_state(state)}, state}
  end

  defp normalize_items(items) when is_list(items) do
    items
    |> Enum.map(&normalize_item/1)
    |> Enum.sort_by(&{&1.priority_rank, &1.identifier})
  end

  defp normalize_item(item) when is_map(item) do
    classification = string_value(item, "classification")
    text_values = known_text_values(item)
    priority = priority_for(item, classification, text_values)

    links =
      item
      |> provided_links()
      |> Enum.concat(extract_links(text_values))
      |> unique_links()

    %{
      identifier: string_value(item, "identifier"),
      title: string_value(item, "title"),
      url: string_value(item, "url"),
      linear_state: string_value(item, "linear_state"),
      project: string_value(item, "project"),
      classification: classification,
      reason: string_value(item, "reason"),
      next_action: string_value(item, "next_action"),
      excerpt: string_value(item, "excerpt"),
      priority_rank: priority.rank,
      priority_label: priority.label,
      priority_reason: priority.reason,
      action_family: priority.action_family,
      action_label: priority.action_label,
      links: links,
      deployment_links:
        item
        |> provided_deployment_links()
        |> Enum.concat(Enum.filter(links, &(&1.kind == "vercel")))
        |> unique_links()
    }
  end

  defp normalize_item(_item) do
    normalize_item(%{})
  end

  defp known_text_values(item) do
    ["url", "title", "reason", "next_action", "excerpt"]
    |> Enum.map(&string_value(item, &1))
    |> Enum.reject(&(&1 == ""))
  end

  defp priority_for(item, classification, text_values) do
    haystack =
      [classification, string_value(item, "linear_state") | text_values]
      |> Enum.join("\n")
      |> String.downcase()

    cond do
      routing_fix?(haystack) ->
        %{
          rank: 0,
          label: "P0 Route",
          reason: "Small routing fix unlocks Symphony dispatch.",
          action_family: "routing",
          action_label: "Add repo routing"
        }

      blocker?(classification, haystack) ->
        %{
          rank: 10,
          label: "P1 Blocker",
          reason: "Currently blocked; this is stopping active work.",
          action_family: "blocker",
          action_label: "Resolve blocker"
        }

      merge_or_pr_review?(haystack) ->
        %{
          rank: 15,
          label: "P1 Review",
          reason: "Review or merge decision can move completed work forward.",
          action_family: "review",
          action_label: "Review PR"
        }

      scope_decision?(haystack) ->
        %{
          rank: 18,
          label: "P2 Scope",
          reason: "Scope decision prevents work from drifting.",
          action_family: "decision",
          action_label: "Decide scope"
        }

      true ->
        {rank, label, reason} = Map.get(@classification_priority, classification, {90, "P9", "Unclassified."})

        %{
          rank: rank,
          label: label,
          reason: reason,
          action_family: classification,
          action_label: default_action_label(classification)
        }
    end
  end

  defp routing_fix?(haystack) do
    String.contains?(haystack, "repos:") or
      String.contains?(haystack, "repository declaration") or
      String.contains?(haystack, "route the workspace") or
      String.contains?(haystack, "reply `retry`") or
      String.contains?(haystack, "reply retry")
  end

  defp blocker?("blocked", _haystack), do: true
  defp blocker?(_classification, haystack), do: String.contains?(haystack, "blocked")

  defp merge_or_pr_review?(haystack) do
    String.contains?(haystack, "review pr") or
      String.contains?(haystack, "pull request") or
      String.contains?(haystack, "github.com") or
      String.contains?(haystack, "approved") or
      String.contains?(haystack, "merge")
  end

  defp scope_decision?(haystack) do
    String.contains?(haystack, "out of scope") or
      String.contains?(haystack, "expand this pr") or
      String.contains?(haystack, "defer")
  end

  defp default_action_label("needs_decision"), do: "Decide"
  defp default_action_label("ready_for_review"), do: "Review"
  defp default_action_label("unanswered_comment"), do: "Reply"
  defp default_action_label("stale_wait"), do: "Check stale"
  defp default_action_label("fyi"), do: "FYI"
  defp default_action_label(classification), do: classification

  defp extract_links(values) do
    values
    |> Enum.flat_map(&Regex.scan(@url_pattern, &1))
    |> Enum.map(fn [url] -> normalize_url(url) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(&link_payload/1)
  end

  defp provided_links(item) when is_map(item) do
    item
    |> Map.get("links", Map.get(item, :links, []))
    |> normalize_provided_links()
  end

  defp provided_deployment_links(item) when is_map(item) do
    item
    |> Map.get("deployment_links", Map.get(item, :deployment_links, []))
    |> normalize_provided_links()
  end

  defp normalize_provided_links(links) when is_list(links) do
    links
    |> Enum.flat_map(fn
      %{} = link ->
        url = string_value(link, "url")

        if url == "" do
          []
        else
          [
            %{
              url: url,
              host: string_value(link, "host"),
              kind: string_value(link, "kind"),
              label: string_value(link, "label")
            }
            |> normalize_link_payload()
          ]
        end

      _other ->
        []
    end)
  end

  defp normalize_provided_links(_links), do: []

  defp normalize_url(url) do
    url
    |> String.trim()
    |> String.replace(@trailing_url_punctuation, "")
  end

  defp link_payload(url) do
    host = url |> URI.parse() |> Map.get(:host)
    kind = if host && String.contains?(host, "vercel"), do: "vercel", else: "reference"

    normalize_link_payload(%{url: url, host: host || url, kind: kind, label: link_label(kind, host || url)})
  rescue
    _error -> %{url: url, host: url, kind: "reference", label: url}
  end

  defp normalize_link_payload(%{url: url, host: host, kind: kind, label: label}) do
    %{
      url: url,
      host: if(host == "", do: url, else: host),
      kind: if(kind == "", do: "reference", else: kind),
      label: if(label == "", do: url, else: label)
    }
  end

  defp unique_links(links) when is_list(links) do
    Enum.uniq_by(links, & &1.url)
  end

  defp link_label("vercel", _host), do: "Vercel deployment"
  defp link_label(_kind, host), do: host

  defp string_value(item, key) when is_map(item) do
    case Map.get(item, key) || Map.get(item, String.to_atom(key)) do
      value when is_binary(value) -> value
      nil -> ""
      value -> to_string(value)
    end
  end

  defp snapshot_from_state(state) do
    %{
      status: state.status,
      items: state.items,
      counts: attention_counts(state.items),
      fetched_at: state.fetched_at,
      expires_at: state.expires_at,
      refreshing: state.refreshing,
      stale: cache_stale?(state),
      error: state.error,
      last_action: state.last_action
    }
  end

  defp unavailable_snapshot do
    %{
      status: "unavailable",
      items: [],
      counts: %{},
      fetched_at: nil,
      expires_at: nil,
      refreshing: false,
      stale: true,
      error: "Attention inbox process is unavailable",
      last_action: nil
    }
  end

  defp attention_counts(items) when is_list(items) do
    items
    |> Enum.group_by(& &1.classification)
    |> Map.new(fn {classification, grouped} -> {classification, length(grouped)} end)
  end

  defp cache_stale?(%{expires_at: nil}), do: true

  defp cache_stale?(%{expires_at: expires_at}) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires_at, _offset} -> DateTime.compare(DateTime.utc_now(), expires_at) in [:gt, :eq]
      _ -> true
    end
  end

  defp action_body("approve", _note), do: "Approved."

  defp action_body("deny", note) do
    normalized_note =
      note
      |> to_string()
      |> String.trim()

    if normalized_note == "" do
      "Revise plan: denied from observability dashboard; revise the plan and return for review."
    else
      "Revise plan: #{normalized_note}"
    end
  end

  defp normalize_action(action) when action in [:approve, "approve"], do: "approve"
  defp normalize_action(action) when action in [:deny, "deny"], do: "deny"
  defp normalize_action(action), do: to_string(action)

  defp configured_fetch_fun do
    Application.get_env(:symphony_elixir, :attention_fetch_fun, &default_fetch/0)
  end

  defp configured_reply_fun do
    Application.get_env(:symphony_elixir, :attention_reply_fun, &default_reply/2)
  end

  defp configured_auto_refresh do
    Application.get_env(:symphony_elixir, :attention_auto_refresh, true)
  end

  defp configured_refresh_ms do
    case Application.get_env(:symphony_elixir, :attention_refresh_ms) || System.get_env("SYMPHONY_ATTENTION_REFRESH_MS") do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive_integer(value, @default_refresh_ms)
      _ -> @default_refresh_ms
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp schedule_refresh(state, delay_ms) do
    if is_reference(state.refresh_timer_ref) do
      Process.cancel_timer(state.refresh_timer_ref)
    end

    %{state | refresh_timer_ref: Process.send_after(self(), :refresh, delay_ms)}
  end

  defp format_reason(reason), do: inspect(reason, limit: 20)

  defp summarize_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp summarize_output(output), do: inspect(output, limit: 20)
end
