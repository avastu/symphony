defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.AttentionInbox
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:attention, load_attention())
      |> assign(:attention_action_message, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:attention, load_attention())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("attention_refresh", _params, socket) do
    case AttentionInbox.refresh(attention_inbox()) do
      {:ok, attention} ->
        {:noreply,
         socket
         |> assign(:attention, attention)
         |> assign(:attention_action_message, "Attention inbox refreshed.")}

      {:error, _reason, attention} ->
        {:noreply,
         socket
         |> assign(:attention, attention)
         |> assign(:attention_action_message, "Attention inbox refresh failed.")}
    end
  end

  def handle_event("attention_approve", %{"issue" => issue_identifier}, socket) do
    handle_attention_action(socket, issue_identifier, :approve, nil)
  end

  def handle_event("attention_deny", %{"issue" => issue_identifier} = params, socket) do
    handle_attention_action(socket, issue_identifier, :deny, Map.get(params, "note"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card attention-section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Attention inbox</h2>
              <p class="section-copy">
                Operator queue ordered by what unlocks the most work first.
              </p>
            </div>

            <button type="button" class="secondary" phx-click="attention_refresh">
              Refresh
            </button>
          </div>

          <div class="attention-meta">
            <span class={attention_status_class(@attention.status)}>
              <%= @attention.status %>
            </span>
            <span :if={@attention.fetched_at} class="muted mono numeric">
              Cached <%= @attention.fetched_at %>
            </span>
            <span :if={@attention.refreshing} class="muted">refreshing...</span>
            <span :if={@attention.stale} class="state-badge state-badge-warning">stale</span>
          </div>

          <p :if={@attention_action_message} class="action-message">
            <%= @attention_action_message %>
          </p>

          <p :if={@attention.error} class="attention-error">
            <%= @attention.error %>
          </p>

          <%= if @attention.items == [] do %>
            <p class="empty-state">No attention items are currently cached.</p>
          <% else %>
            <% top_item = List.first(@attention.items) %>
            <div class="attention-summary" aria-label="Attention priority summary">
              <div class="attention-summary-item attention-summary-route">
                <span class="attention-summary-label">Routing fixes</span>
                <strong class="numeric"><%= attention_action_count(@attention.items, "routing") %></strong>
              </div>
              <div class="attention-summary-item attention-summary-blocker">
                <span class="attention-summary-label">Blockers</span>
                <strong class="numeric"><%= attention_action_count(@attention.items, "blocker") %></strong>
              </div>
              <div class="attention-summary-item attention-summary-review">
                <span class="attention-summary-label">PR / merge review</span>
                <strong class="numeric"><%= attention_action_count(@attention.items, "review") %></strong>
              </div>
              <div class="attention-summary-item">
                <span class="attention-summary-label">Total</span>
                <strong class="numeric"><%= length(@attention.items) %></strong>
              </div>
            </div>

            <aside :if={top_item} class="attention-start">
              <div>
                <p class="attention-start-label">Start here</p>
                <h3 class="attention-start-title">
                  <a href={top_item.url} target="_blank" rel="noreferrer">
                    <%= top_item.action_label %>: <%= top_item.identifier %>
                  </a>
                </h3>
                <p class="attention-start-copy"><%= top_item.priority_reason %></p>
              </div>
              <span class={priority_badge_class(top_item.priority_rank)}>
                <%= top_item.priority_label %>
              </span>
            </aside>

            <div class="attention-list">
              <article
                :for={{item, index} <- Enum.with_index(@attention.items)}
                class={[
                  "attention-item",
                  "attention-rank-#{item.priority_rank}",
                  index == 0 && "attention-item-primary"
                ]}
              >
                <div class="attention-main">
                  <div class="attention-topline">
                    <span class={priority_badge_class(item.priority_rank)}>
                      <%= item.priority_label %>
                    </span>
                    <span class="action-badge">
                      <%= item.action_label %>
                    </span>
                    <span class={attention_classification_class(item.classification)}>
                      <%= item.classification %>
                    </span>
                    <span class={state_badge_class(item.linear_state)}>
                      <%= item.linear_state %>
                    </span>
                    <span :if={item.project != ""} class="muted">
                      <%= item.project %>
                    </span>
                  </div>

                  <h3 class="attention-title">
                    <a href={item.url} target="_blank" rel="noreferrer"><%= item.identifier %>: <%= item.title %></a>
                  </h3>

                  <p class="attention-copy"><strong>Priority:</strong> <%= item.priority_reason %></p>
                  <p class="attention-copy"><strong>Why:</strong> <%= item.reason %></p>
                  <p class="attention-copy"><strong>Next:</strong> <%= item.next_action %></p>
                  <p :if={item.excerpt != ""} class="attention-excerpt"><%= item.excerpt %></p>

                  <div :if={item.deployment_links != []} class="attention-links">
                    <a
                      :for={link <- item.deployment_links}
                      class="deployment-link"
                      href={link.url}
                      target="_blank"
                      rel="noreferrer"
                    >
                      <%= link.label %>
                    </a>
                  </div>
                </div>

                <div class="attention-actions">
                  <button
                    type="button"
                    class="subtle-button approve-button"
                    phx-click="attention_approve"
                    phx-value-issue={item.identifier}
                  >
                    Approve
                  </button>

                  <form class="deny-form" phx-submit="attention_deny">
                    <input type="hidden" name="issue" value={item.identifier} />
                    <input
                      class="deny-input"
                      type="text"
                      name="note"
                      placeholder="Change request"
                      aria-label={"Change request for #{item.identifier}"}
                    />
                    <button type="submit" class="subtle-button deny-button">Deny</button>
                  </form>
                </div>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_attention do
    AttentionInbox.snapshot(attention_inbox())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp attention_inbox do
    Endpoint.config(:attention_inbox) || AttentionInbox
  end

  defp handle_attention_action(socket, issue_identifier, action, note) do
    result =
      case action do
        :approve -> AttentionInbox.act(attention_inbox(), issue_identifier, :approve)
        :deny -> AttentionInbox.act(attention_inbox(), issue_identifier, :deny, note: note)
      end

    case result do
      {:ok, attention} ->
        {:noreply,
         socket
         |> assign(:attention, attention)
         |> assign(:attention_action_message, attention_action_success_message(issue_identifier, action))}

      {:error, _reason, attention} ->
        {:noreply,
         socket
         |> assign(:attention, attention)
         |> assign(:attention_action_message, attention_action_failure_message(issue_identifier, action))}
    end
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp attention_status_class("ready"), do: "state-badge state-badge-active"
  defp attention_status_class("error"), do: "state-badge state-badge-danger"
  defp attention_status_class("unavailable"), do: "state-badge state-badge-danger"
  defp attention_status_class(_status), do: "state-badge"

  defp priority_badge_class(0), do: "priority-badge priority-badge-critical"
  defp priority_badge_class(1), do: "priority-badge priority-badge-high"
  defp priority_badge_class(2), do: "priority-badge priority-badge-review"
  defp priority_badge_class(_rank), do: "priority-badge"

  defp attention_classification_class(classification) do
    "classification-badge classification-#{classification}"
  end

  defp attention_action_count(items, action_family) when is_list(items) do
    Enum.count(items, &(&1.action_family == action_family))
  end

  defp attention_action_count(_items, _action_family), do: 0

  defp attention_action_success_message(issue_identifier, :approve) do
    "Posted approval for #{issue_identifier}."
  end

  defp attention_action_success_message(issue_identifier, :deny) do
    "Posted change request for #{issue_identifier}."
  end

  defp attention_action_failure_message(issue_identifier, :approve) do
    "Failed to post approval for #{issue_identifier}."
  end

  defp attention_action_failure_message(issue_identifier, :deny) do
    "Failed to post change request for #{issue_identifier}."
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
