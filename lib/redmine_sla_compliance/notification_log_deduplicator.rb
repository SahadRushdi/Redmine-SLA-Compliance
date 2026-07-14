# frozen_string_literal: true

module RedmineSlaCompliance
  # Migration 002 support: before the (issue_id, notification_type, target) unique index can be
  # created, any duplicate rows already written by the pre-fix check-then-act race
  # (`already_sent?` + `create!`) must be collapsed to one row per key — otherwise `add_index
  # unique: true` aborts on the very first real database it runs against (an empty test DB never
  # exercises this path, which is exactly how the original migration shipped with the bug).
  #
  # Kept as a standalone class (not inlined in the migration) so it's unit-testable like any other
  # piece of logic: seed real duplicate rows, run it, assert exactly one row per key survives.
  #
  # Must run AFTER any NULL `target` values have been backfilled to '' — SQL's `t1.target =
  # t2.target` does not match two NULLs (NULL = NULL is NULL, not true), so grouping while target
  # is still nullable would silently skip exactly the rows that need deduping.
  class NotificationLogDeduplicator
    # For each (issue_id, notification_type, target) group with more than one row, keeps the row
    # with the earliest COALESCE(sent_at, created_at) — "earliest sent_at", falling back to when
    # it was queued for rows never marked sent — tie-broken by the lowest id, and deletes the
    # rest. A plain multi-table DELETE (no window functions) so it works on older MySQL too.
    def self.run!
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        DELETE t1 FROM sla_notification_logs t1
        INNER JOIN sla_notification_logs t2
          ON t1.issue_id = t2.issue_id
         AND t1.notification_type = t2.notification_type
         AND t1.target = t2.target
        WHERE (COALESCE(t1.sent_at, t1.created_at) > COALESCE(t2.sent_at, t2.created_at))
           OR (COALESCE(t1.sent_at, t1.created_at) = COALESCE(t2.sent_at, t2.created_at)
               AND t1.id > t2.id)
      SQL
    end
  end
end
