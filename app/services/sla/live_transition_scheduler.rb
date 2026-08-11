# frozen_string_literal: true

module Sla
  # Schedules only the next known time transitions for one issue. Unlike the retired sweep, this
  # never scans projects or tickets. Jobs carry the cache calculation timestamp as a token; an
  # issue edit writes a newer result, making every older queued transition a harmless no-op.
  class LiveTransitionScheduler
    def self.call(issue, outcome, now: Time.current)
      new(issue, outcome, now: now).call
    end

    def initialize(issue, outcome, now:)
      @issue = issue
      @outcome = outcome
      @now = now
    end

    def call
      notify_at_risk if @outcome.newly_at_risk?
      schedule(:at_risk, @outcome.record.at_risk_at)
      schedule(:breach, @outcome.record.breach_at)
    end

    private

    def schedule(transition, at)
      return if at.blank? || at <= @now

      # Breach semantics are strict (`elapsed > target`), so execute one second after breach_at;
      # dashboard SQL uses the same strict boundary in the meantime.
      execute_at = transition == :breach ? at + 1.second : at
      SlaLiveTransitionJob.set(wait_until: execute_at).perform_later(
        @issue.id, @outcome.record.calculated_at.to_i, transition.to_s, at.to_i
      )
    rescue NotImplementedError => e
      # Rails' :inline test/development adapter cannot enqueue future work. The indexed dashboard
      # projection remains correct; never let an adapter limitation break an issue save.
      Rails.logger.warn("[SLA] future #{transition} job not queued for issue ##{@issue.id}: #{e.message}")
    end

    def notify_at_risk
      setting = NotificationSettingsResolver.new(@issue.project).resolve(:at_risk_email).setting
      return unless setting

      result = @outcome.result
      target = result&.at_risk_target.presence || SlaNotificationLog::NO_TARGET
      episode = result&.at_risk_since || result&.cycle_started_at
      return unless SlaNotificationLog.claim!(issue_id: @issue.id, notification_type: 'at_risk',
                                               target: target,
                                               cycle_key: episode&.to_i&.to_s || SlaNotificationLog::NO_CYCLE)

      AtRiskNotifier.new.enqueue_at_risk(@issue, @outcome.record, setting: setting)
    end
  end
end
