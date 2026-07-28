# frozen_string_literal: true

module Sla
  # Dashboard "Stale" card count: OPEN tickets in the given sla_results scope that have had no
  # updates for at least their project's configured inactivity threshold
  # (SlaNotificationSetting#stale_threshold_days, DB default 7). "No updates" is measured off
  # issues.updated_on — Redmine bumps that on any note, status change, or edit, which is exactly
  # the "no any changes" the dashboard's Stale card reports.
  #
  # A cache/DB-only read (Global Rule 4): a single aggregate query over the already-filtered
  # relation, never the per-ticket timeline reconstruction Sla::StaleTicketDetector does for the
  # notification sweep. The threshold is genuinely per-project (a multi-project dashboard scope can
  # span several), so each project's own cutoff is applied via an OR of (project_id, cutoff) pairs
  # rather than one global cutoff — projects with no notification setting fall back to the same
  # default the column carries.
  #
  # "Open" is `sla_results.resolved_at IS NULL` — the plugin's own definition (not in a configured
  # `resolved`-role status), the same one Sla::DashboardScope#open_only applies, so the Stale card
  # and the Total Open Tickets card always describe the same population. A resolved ticket that
  # simply hasn't been touched since is not "stale", it's done. Kept here rather than relying on
  # the caller's scope because the notification path also calls this with an unfiltered relation.
  class StaleSummary
    DEFAULT_THRESHOLD_DAYS = 7 # mirrors the sla_notification_settings.stale_threshold_days column default

    def self.call(scope:, now: Time.current)
      new(scope: scope, now: now).call
    end

    def initialize(scope:, now: Time.current)
      @scope = scope
      @now   = now
    end

    def call
      base = @scope.reorder(nil).unscope(:includes).joins(:issue)
                   .where(sla_results: { resolved_at: nil })

      project_ids = base.distinct.pluck(:project_id)
      return 0 if project_ids.empty?

      base.where(stale_condition(project_ids)).count
    end

    private

    # One "(project_id = ? AND issues.updated_on < ?)" clause per project, each using that
    # project's own inactivity cutoff, OR'd together — so a single COUNT resolves the whole
    # (possibly multi-project) scope with the correct per-project threshold applied to each row.
    def stale_condition(project_ids)
      thresholds = threshold_days_by_project(project_ids)
      clauses = project_ids.map do |pid|
        days   = thresholds[pid] || DEFAULT_THRESHOLD_DAYS
        cutoff = @now - days.days
        # `<=`, not `<`: matches Sla::StaleTicketDetector's inclusive `inactive_seconds >= threshold`
        # boundary, so a ticket idle for exactly the threshold counts as stale in both paths.
        ActiveRecord::Base.sanitize_sql_array(['(sla_results.project_id = ? AND issues.updated_on <= ?)', pid, cutoff])
      end
      clauses.join(' OR ')
    end

    def threshold_days_by_project(project_ids)
      SlaNotificationSetting.where(project_id: project_ids).pluck(:project_id, :stale_threshold_days).to_h
    end
  end
end
