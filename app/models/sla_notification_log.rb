# frozen_string_literal: true

# Ledger of sent notifications, used for dedup and digest batching (Phases 7-8). The sweep is
# idempotent: it consults this log so a ticket+target is never notified twice.
class SlaNotificationLog < ActiveRecord::Base
  self.table_name = 'sla_notification_logs'

  # Plugin-internal enums.
  TYPES   = %w[at_risk stale google_chat_created].freeze
  TARGETS = %w[response workaround resolution].freeze

  belongs_to :issue, optional: true

  validates :issue_id, presence: true
  validates :notification_type, inclusion: { in: TYPES }
  validates :target, inclusion: { in: TARGETS }, allow_nil: true

  # Has this ticket+type(+target) already been sent?
  def self.already_sent?(issue_id:, notification_type:, target: nil)
    where(issue_id: issue_id, notification_type: notification_type, target: target).exists?
  end
end
