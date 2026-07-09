# frozen_string_literal: true

# Per-project notification configuration: Google Chat webhook, at-risk email (real-time or
# digest) and stale-ticket email. Recipient lists are stored as JSON arrays of addresses.
class SlaNotificationSetting < ActiveRecord::Base
  self.table_name = 'sla_notification_settings'

  # Plugin-internal frequency enums.
  AT_RISK_FREQUENCIES = %w[realtime digest].freeze
  STALE_FREQUENCIES   = %w[daily weekly monthly].freeze

  belongs_to :project

  serialize :at_risk_email_recipients, JSON
  serialize :stale_email_recipients, JSON

  validates :project_id, presence: true, uniqueness: true
  validates :at_risk_email_frequency, inclusion: { in: AT_RISK_FREQUENCIES }
  validates :stale_email_frequency, inclusion: { in: STALE_FREQUENCIES }
  validates :at_risk_digest_interval_minutes,
            numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :recipients_are_valid_emails

  private

  EMAIL_RE = URI::MailTo::EMAIL_REGEXP

  def recipients_are_valid_emails
    { at_risk_email_recipients: at_risk_email_recipients,
      stale_email_recipients: stale_email_recipients }.each do |attr, list|
      next if list.blank?
      unless list.is_a?(Array) && list.all? { |e| e.to_s.match?(EMAIL_RE) }
        errors.add(attr, :invalid)
      end
    end
  end
end
