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
  validates :stale_threshold_days,
            numericality: { only_integer: true, greater_than: 0 }
  validate :recipients_are_valid_emails

  FREQUENCY_INTERVALS = { 'daily' => 1.day, 'weekly' => 1.week, 'monthly' => 1.month }.freeze

  # How much wall-clock time must pass between stale-ticket digests, per the configured
  # frequency (defaults to weekly per the plan's Fixed Decisions if an unknown value sneaks in).
  def stale_digest_interval
    FREQUENCY_INTERVALS.fetch(stale_email_frequency, 1.week)
  end

  # Atomically claim +project_id+'s stale-digest window: this is the sweep's schedule gate,
  # mirroring `SlaNotificationLog.claim!`'s use of a real DB constraint instead of an app-level
  # check-then-act. The conditional `UPDATE ... WHERE` only affects a row (and returns 1) if no
  # other process has already claimed this window — safe under concurrent sweeps across multiple
  # app-server workers. Returns the setting (for its recipients/threshold) when this call won the
  # claim, or nil when digests are disabled or another process already claimed this period.
  def self.claim_stale_digest_window!(project_id, now: Time.current)
    setting = find_by(project_id: project_id)
    return nil unless setting&.stale_email_enabled?

    cutoff = now - setting.stale_digest_interval
    claimed_rows = where(id: setting.id)
                   .where('last_stale_digest_at IS NULL OR last_stale_digest_at <= ?', cutoff)
                   .update_all(last_stale_digest_at: now)
    claimed_rows == 1 ? setting : nil
  end

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
