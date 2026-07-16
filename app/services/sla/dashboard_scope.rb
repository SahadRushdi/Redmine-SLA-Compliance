# frozen_string_literal: true

module Sla
  # The filtered `sla_results` relation for the dashboard (Step 6.1). `sla_results` itself has no
  # tracker_id/priority_id/created_on columns (see the `sla_` migration), so every filter here
  # joins `issues`. Built as its own service — not inline controller ActiveRecord — because Steps
  # 6.3/6.4 (charts, detail table) need this exact same filtered relation; composing it once here
  # avoids duplicating the join/filter logic across every dashboard consumer.
  #
  # Deliberately does not scope by permission or resolve which projects/trackers/priorities are
  # valid — the caller (SlaDashboardController#resolve_filters) is responsible for clamping
  # user-submitted ids against what's actually permitted/configured before calling this.
  class DashboardScope
    def self.call(project_ids:, tracker_id: nil, priority_ids: [], date_range: nil)
      new(project_ids: project_ids, tracker_id: tracker_id, priority_ids: priority_ids,
          date_range: date_range).call
    end

    def initialize(project_ids:, tracker_id: nil, priority_ids: [], date_range: nil)
      @project_ids = project_ids
      @tracker_id = tracker_id
      @priority_ids = priority_ids
      @date_range = date_range
    end

    def call
      scope = SlaResult.joins(:issue).where(project_id: @project_ids)
      scope = scope.where(issues: { tracker_id: @tracker_id }) if @tracker_id
      scope = scope.where(issues: { priority_id: @priority_ids }) if @priority_ids.present?
      scope = scope.where(issues: { created_on: @date_range }) if @date_range
      scope
    end
  end
end
