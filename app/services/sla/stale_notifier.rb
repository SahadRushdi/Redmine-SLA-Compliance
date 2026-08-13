# frozen_string_literal: true

module Sla
  # The sweep detects a project's stale-digest window coming due and hands the qualifying tickets
  # here to be queued. Phase 8 (Email Notifications) replaces this body with the real digest
  # mailer; keeping it a small injectable object lets the sweep's scheduling behavior be fully
  # tested without any mail infrastructure yet — mirrors `AtRiskNotifier`.
  class StaleNotifier
    # @param project [Project]
    # @param issues  [Array<Issue>] open, no_sla/not_tracked issues stale past the project's
    #   configured threshold
    def enqueue_stale_digest(project, logs, setting:)
      queued = logs.select(&:queue!)
      return false if queued.empty?

      SlaEmailDeliveryJob.perform_later('stale_digest', project.id, queued.map(&:id), setting.id)
      true
    rescue StandardError => e
      Array(queued || logs).each { |log| log.failed!(e) }
      Rails.logger.error("[SLA] stale email enqueue failed for project ##{project.id}: #{e.class}: #{e.message}")
      false
    end
  end
end
