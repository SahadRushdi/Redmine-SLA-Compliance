# frozen_string_literal: true

class SlaEmailDeliveryJob < ApplicationJob
  queue_as :default

  def perform(kind, project_id, log_ids, setting_id)
    project = Project.find_by(id: project_id)
    setting = SlaNotificationSetting.find_by(id: setting_id)
    logs = SlaNotificationLog.where(id: Array(log_ids), delivery_state: 'queued').order(:id).to_a
    return if project.nil? || setting.nil? || logs.empty?

    channel = kind == 'stale_digest' ? :stale : :at_risk
    recipients = Sla::EmailRecipientResolver.for(setting, channel: channel, project: project).to_a
    raise StandardError, 'no eligible project recipients' if recipients.empty?

    recipients.each { |user| build_message(kind, user, project, logs).deliver_now }
    logs.each(&:sent!)
  rescue StandardError => e
    Array(logs).each { |log| log.failed!(e) }
    Rails.logger.error("[SLA] email delivery failed kind=#{kind} project_id=#{project_id}: #{e.class}: #{e.message}")
    nil
  end

  private

  def build_message(kind, user, project, logs)
    case kind
    when 'at_risk_realtime'
      SlaMailer.at_risk_alert(user, Issue.find(logs.first.issue_id), logs.first)
    when 'at_risk_digest'
      SlaMailer.at_risk_digest(user, project, logs)
    when 'stale_digest'
      SlaMailer.stale_digest(user, project, logs)
    else
      raise ArgumentError, "unknown SLA email kind #{kind.inspect}"
    end
  end
end
