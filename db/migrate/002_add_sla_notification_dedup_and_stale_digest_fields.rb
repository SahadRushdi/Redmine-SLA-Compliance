# Phase 3 hardening:
#
# 1. `sla_notification_logs.target` was nullable, and the dedup index on
#    [issue_id, notification_type, target] was NOT unique — so the sweep's dedup guard was a pure
#    app-level check-then-act (`already_sent?` then `create!`), which races across the multiple
#    app-server worker processes that each run their own copy of the sweep scheduler. MySQL (and
#    Postgres) treat NULL as distinct from NULL in a unique index, so even making the index unique
#    without also giving `target` a non-null sentinel would silently fail to protect the at-risk
#    rows (which pass target: nil). We backfill existing NULLs to '' ("no specific
#    milestone target" — used by ticket-level notification types like at_risk and stale) and make
#    the column NOT NULL with that default, so the unique index can do real work and
#    `SlaNotificationLog.claim!` can rely on the DB, not application logic, for atomicity.
#
# 2. Stale-ticket digest scheduling (Step 3.3) needs two new configurable pieces of per-project
#    state that didn't exist yet:
#      - `stale_threshold_days` — the "configurable period" of inactivity that makes a No-SLA
#        ticket "stale" (plan §3 Fixed Decisions). Separate from `stale_email_frequency`, which is
#        how often the digest itself is sent.
#      - `last_stale_digest_at` — the cadence gate the sweep claims atomically (mirrors the
#        dedup-by-unique-index approach above, but via a conditional UPDATE) so only one process's
#        sweep run "wins" the digest window per project per period.
class AddSlaNotificationDedupAndStaleDigestFields < ActiveRecord::Migration[6.1]
  def up
    unless column_exists?(:sla_notification_logs, :target) &&
           columns(:sla_notification_logs).find { |c| c.name == 'target' }.null == false
      change_column_null :sla_notification_logs, :target, false, ''
      change_column_default :sla_notification_logs, :target, ''
    end

    if index_exists?(:sla_notification_logs, [:issue_id, :notification_type, :target],
                     name: 'idx_sla_notification_logs_dedup')
      remove_index :sla_notification_logs, name: 'idx_sla_notification_logs_dedup'
    end
    unless index_exists?(:sla_notification_logs, [:issue_id, :notification_type, :target],
                         name: 'idx_sla_notification_logs_dedup_uniq')
      add_index :sla_notification_logs, [:issue_id, :notification_type, :target],
                unique: true, name: 'idx_sla_notification_logs_dedup_uniq'
    end

    unless column_exists?(:sla_notification_settings, :stale_threshold_days)
      add_column :sla_notification_settings, :stale_threshold_days, :integer,
                 null: false, default: 7
    end
    unless column_exists?(:sla_notification_settings, :last_stale_digest_at)
      add_column :sla_notification_settings, :last_stale_digest_at, :datetime
    end
  end

  def down
    remove_column :sla_notification_settings, :last_stale_digest_at, if_exists: true
    remove_column :sla_notification_settings, :stale_threshold_days, if_exists: true

    if index_exists?(:sla_notification_logs, [:issue_id, :notification_type, :target],
                     name: 'idx_sla_notification_logs_dedup_uniq')
      remove_index :sla_notification_logs, name: 'idx_sla_notification_logs_dedup_uniq'
    end
    unless index_exists?(:sla_notification_logs, [:issue_id, :notification_type, :target],
                         name: 'idx_sla_notification_logs_dedup')
      add_index :sla_notification_logs, [:issue_id, :notification_type, :target],
                name: 'idx_sla_notification_logs_dedup'
    end

    change_column_null :sla_notification_logs, :target, true
    change_column_default :sla_notification_logs, :target, nil
  end
end
