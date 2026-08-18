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
  # times. The selected date range must not reach it. Created-vs-Resolved is the only historical
  # dashboard surface, so Sla::TrendSeries takes an unfiltered scope and applies independent ranges
  # to issues.created_on and sla_results.resolved_at itself.
  #
  # Deliberately does not scope by permission or resolve which projects/trackers/priorities are
  # valid — the caller (SlaDashboardController#resolve_filters) is responsible for clamping
  # user-submitted ids against what's actually permitted/configured before calling this.
  class DashboardScope
    def self.call(project_ids:, tracker_ids: [], priority_ids: [], open_only: false)
      new(project_ids: project_ids, tracker_ids: tracker_ids, priority_ids: priority_ids,
          open_only: open_only).call
    end

    def initialize(project_ids:, tracker_ids: [], priority_ids: [], open_only: false)
      @project_ids = project_ids
      @tracker_ids = tracker_ids
      @priority_ids = priority_ids
      @open_only = open_only
    end

    def call
      scope = SlaResult.joins(:issue)
                       .where(project_id: @project_ids, primary_state: %w[met breached])
      scope = scope.where(issues: { tracker_id: @tracker_ids }) if @tracker_ids.present?
      scope = scope.where(issues: { priority_id: @priority_ids }) if @priority_ids.present?
      # Open = not resolved, per the engine's own `resolved`-role statuses rather than Redmine's
      # is_closed flag (Sla::ResultClassifier#closed_at persists the instant into `resolved_at`).
      scope = scope.where(sla_results: { resolved_at: nil }) if @open_only
      scope
    end
  end
end
