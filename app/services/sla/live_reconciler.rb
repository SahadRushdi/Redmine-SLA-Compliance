# frozen_string_literal: true

module Sla
  # One-time/recovery bridge for deployments and queue downtime. Recalculation writes current
  # projections and schedules targeted jobs; pending legacy digest claims are delivered as the
  # immediate alerts selected by the current notification model.
  class LiveReconciler
    Summary = Struct.new(:recalculated, :legacy_queued, keyword_init: true)

    def run
      recalculated = Project.active.has_module(:sla_compliance).sum do |project|
        ProjectRecalculator.run(project, include_descendants: false)
      end
      Summary.new(recalculated: recalculated, legacy_queued: drain_legacy_claims)
    end

    private

    def drain_legacy_claims
      count = 0
      SlaNotificationLog.includes(issue: :project)
                        .where(notification_type: %w[at_risk stale], delivery_state: 'pending')
                        .find_each do |log|
        issue = log.issue
        next unless issue&.project&.active? && issue.project.module_enabled?(:sla_compliance)

        channel = log.notification_type == 'stale' ? :stale_email : :at_risk_email
        setting = NotificationSettingsResolver.new(issue.project).resolve(channel).setting
        next unless setting

        queued = if log.notification_type == 'stale'
                   StaleNotifier.new.enqueue_stale(issue, setting: setting, log: log)
                 else
                   AtRiskNotifier.new.enqueue_at_risk(issue, SlaResult.find_by(issue_id: issue.id),
                                                       setting: setting, log: log)
                 end
        count += 1 if queued
      end
      count
    end
  end
end
