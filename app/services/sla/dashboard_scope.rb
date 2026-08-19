# frozen_string_literal: true

module Sla
  # The filtered, evaluated `sla_results` relation for the dashboard (Step 6.1). No-SLA rows stay
  # in the cache for engine/notification purposes but are deliberately absent from every dashboard
  # consumer (cards, charts, trends, detail rows and CSV). `sla_results` itself has no
  # tracker_id/priority_id columns (see the `sla_` migration), so those filters join `issues`.
  # Built as its own service — not inline controller ActiveRecord — because Steps 6.3/6.4 (charts,
  # detail table) need this exact same filtered relation; composing it once here avoids duplicating
  # the join/filter logic across every dashboard consumer.
  #
  # `open_only` defines the current dashboard population: every ticket not yet resolved, at all
  # times. `resolved_range` defines the SLA Trend card's historical outcome population: tickets
  # whose engine-cached resolution milestone falls inside the selected period. `cycle_started_range`
  # remains available to consumers that need the configured Created/reopen milestone cohort.
  #
  # Deliberately does not scope by permission or resolve which projects/trackers/priorities are
  # valid — the caller (SlaDashboardController#resolve_filters) is responsible for clamping
  # user-submitted ids against what's actually permitted/configured before calling this.
  class DashboardScope
    def self.call(project_ids:, tracker_ids: [], priority_ids: [], open_only: false,
                  cycle_started_range: nil, resolved_range: nil)
      new(project_ids: project_ids, tracker_ids: tracker_ids, priority_ids: priority_ids,
          open_only: open_only, cycle_started_range: cycle_started_range,
          resolved_range: resolved_range).call
    end

    def initialize(project_ids:, tracker_ids: [], priority_ids: [], open_only: false,
                   cycle_started_range: nil, resolved_range: nil)
      @project_ids = project_ids
      @tracker_ids = tracker_ids
      @priority_ids = priority_ids
      @open_only = open_only
      @cycle_started_range = cycle_started_range
      @resolved_range = resolved_range
    end

    def call
      scope = SlaResult.joins(:issue)
                       .where(project_id: @project_ids, primary_state: %w[met breached])
      scope = scope.where(issues: { tracker_id: @tracker_ids }) if @tracker_ids.present?
      scope = scope.where(issues: { priority_id: @priority_ids }) if @priority_ids.present?
      # Open = not resolved, per the engine's own `resolved`-role statuses rather than Redmine's
      # is_closed flag (Sla::ResultClassifier#closed_at persists the instant into `resolved_at`).
      scope = scope.where(sla_results: { resolved_at: nil }) if @open_only
      if @cycle_started_range
        scope = scope.where(sla_results: { cycle_started_at: timestamp_range(@cycle_started_range) })
      end
      if @resolved_range
        scope = scope.where(sla_results: { resolved_at: timestamp_range(@resolved_range) })
      end
      scope
    end

    private

    def timestamp_range(date_range)
      date_range.first.beginning_of_day..date_range.last.end_of_day
    end
  end
end
