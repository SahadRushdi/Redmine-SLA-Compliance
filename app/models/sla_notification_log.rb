# frozen_string_literal: true

# Ledger of sent notifications, used for dedup and digest batching (Phases 7-8). The sweep is
# idempotent: it consults this log so a ticket+target+cycle is never notified twice.
class SlaNotificationLog < ActiveRecord::Base
  self.table_name = 'sla_notification_logs'

  # Plugin-internal enums. `target` is '' (not nil — see migration 002) for ticket-level
  # notification types (at_risk, stale) that aren't about one specific milestone.
  TYPES   = %w[at_risk stale google_chat_created].freeze
  TARGETS = %w[response workaround resolution].freeze
  NO_TARGET = ''
  NO_CYCLE = ''

  belongs_to :issue, optional: true

  validates :issue_id, presence: true
  validates :notification_type, inclusion: { in: TYPES }
  validates :target, inclusion: { in: TARGETS }, allow_blank: true

  # Has this ticket+type+target(+cycle) already been sent?
  def self.already_sent?(issue_id:, notification_type:, target: NO_TARGET, cycle_key: NO_CYCLE)
    where(issue_id: issue_id, notification_type: notification_type, target: target,
          cycle_key: cycle_key).exists?
  end

  # Atomically claim the (issue, type, target, cycle) slot: returns true the first time it's
  # called for a given combination, false on every subsequent call — including calls racing from
  # other processes. Unlike `already_sent?` + `create!`, this has no check-then-act window: the
  # DB's unique index (migration 002) is the sole source of truth, so it is safe to call from many
  # app-server workers running their own copy of the sweep at the same time.
  #
  # `cycle_key` is what makes this a per-cycle claim rather than a lifetime one: pass the engine's
  # measurement-cycle start (for at-risk — a reopened ticket gets a new clock_start and so a new
  # cycle_key, letting it be notified again) or the digest window's claimed instant (for stale — a
  # still-stale ticket gets a fresh cycle_key every window, so it keeps appearing in digests
  # instead of being silently suppressed forever after its first appearance).
  def self.claim!(issue_id:, notification_type:, target: NO_TARGET, cycle_key: NO_CYCLE)
    create!(issue_id: issue_id, notification_type: notification_type, target: target,
            cycle_key: cycle_key.to_s, sent_at: nil)
    true
  rescue ActiveRecord::RecordNotUnique
    false
  end
end
