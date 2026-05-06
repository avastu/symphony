defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :project_name,
    :project_slug,
    :project_url,
    :assignee_id,
    :workpad_state,
    :workpad_phase,
    :review_action,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          project_name: String.t() | nil,
          project_slug: String.t() | nil,
          project_url: String.t() | nil,
          assignee_id: String.t() | nil,
          workpad_state: String.t() | nil,
          workpad_phase: String.t() | nil,
          review_action: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec project_label(t()) :: String.t() | nil
  def project_label(%__MODULE__{project_name: name, project_slug: slug}) do
    case {project_label_part(name), project_label_part(slug)} do
      {nil, nil} -> nil
      {name, nil} -> name
      {nil, slug} -> slug
      {name, slug} -> "#{name} (#{slug})"
    end
  end

  def project_label(_issue), do: nil

  defp project_label_part(value) when is_binary(value) and value != "", do: value
  defp project_label_part(_value), do: nil
end
