require_relative '../../lib/redmine_sla_compliance/notification_log_deduplicator'

# Phase 3 hardening:
#
# 1. `sla_notification_logs.target` was nullable, and the dedup index on
#    [issue_id, notification_type, target] was NOT unique — so the sweep's dedup guard was a pure
#    app-level check-then-act (`already_sent?` then `create!`), which races across the multiple
#    app-server worker processes that each run their own copy of the sweep scheduler. Before the
#    unique index can be created, any duplicate rows the race already produced on a real database
#    must be collapsed to one per key (`NotificationLogDeduplicator`) — an empty test DB never
#    exercises this, which is how the original version of this migration shipped with a landmine:
#    `add_index unique: true` aborts the instant it meets real duplicate data.
#
# 2. A DB-unique claim keyed on (issue_id, notification_type, target) alone is a LIFETIME claim.
#    But reopened tickets restart the SLA clock from zero (plan §3 Fixed Decisions), so
#    at-risk -> notified -> resolved -> reopened -> at-risk again must produce a SECOND
#    notification — the old 3-column key would silently block it forever. The same problem hits
#    the stale digest: a still-stale ticket must appear in every subsequent digest window, not
#    just once, ever. Both are fixed by a 4th discriminator column, `cycle_key`: for at-risk
#    claims it's the engine's measurement-cycle start time (`sla_results.cycle_started_at`, also
#    added here); for stale claims it's the digest window's claimed instant. Two claims with the
#    same issue/type/target but a DIFFERENT cycle_key are legitimately different notifications.
#
# 3. Stale-ticket digest scheduling (Step 3.3) needs two new configurable pieces of per-project
#    state that didn't exist yet:
#      - `stale_threshold_days` — the "configurable period" of inactivity that makes a No-SLA
#        ticket "stale" (plan §3 Fixed Decisions). Separate from `stale_email_frequency`, which is
#        how often the digest itself is sent.
#      - `last_stale_digest_at` — the cadence gate the sweep claims atomically (a conditional
#        UPDATE) so only one process's sweep run "wins" the digest window per project per period.
#
# 4. `sla_sweep_state` is a new one-row singleton table giving the sweep itself the same
#    atomic-claim treatment as the stale digest: without it, every app-server worker process runs
#    its own full copy of the sweep every interval (N workers = N x the recompute load for no
#    correctness benefit, since the notification dedup above already makes duplicate sweeps safe —
#    just wasteful). `SlaSweepState.claim_run!` lets only one worker actually do the work per
#    interval.
class AddSlaNotificationDedupAndStaleDigestFields < ActiveRecord::Migration[6.1]
  def up
    # --- 1 + 2: notification log dedup guard -------------------------------------------------
    # Backfill NULL -> '' BEFORE dedup: the dedup join compares target with plain `=`, which does
    # not match two NULLs, so deduping first would silently miss exactly the legacy at-risk rows
    # (which always used target: nil) most likely to have duplicates.
    unless column_null_false?(:sla_notification_logs, :target)
      execute "UPDATE sla_notification_logs SET target = '' WHERE target IS NULL"
      RedmineSlaCompliance::NotificationLogDeduplicator.run!
      change_column_null :sla_notification_logs, :target, false, ''
      change_column_default :sla_notification_logs, :target, ''
    end

    unless column_exists?(:sla_notification_logs, :cycle_key)
      add_column :sla_notification_logs, :cycle_key, :string, limit: 40, null: false, default: ''
    end

    %w[idx_sla_notification_logs_dedup idx_sla_notification_logs_dedup_uniq].each do |name|
      remove_index :sla_notification_logs, name: name if index_name_exists?(:sla_notification_logs, name)
    end
    unless index_exists?(:sla_notification_logs, [:issue_id, :notification_type, :target, :cycle_key],
                         name: 'idx_sla_notification_logs_dedup_uniq')
      add_index :sla_notification_logs, [:issue_id, :notification_type, :target, :cycle_key],
                unique: true, name: 'idx_sla_notification_logs_dedup_uniq'
    end

    unless column_exists?(:sla_results, :cycle_started_at)
      add_column :sla_results, :cycle_started_at, :datetime
    end

    # --- 3: stale-digest schedule state --------------------------------------------------------
    unless column_exists?(:sla_notification_settings, :stale_threshold_days)
      add_column :sla_notification_settings, :stale_threshold_days, :integer,
                 null: false, default: 7
    end
    unless column_exists?(:sla_notification_settings, :last_stale_digest_at)
      add_column :sla_notification_settings, :last_stale_digest_at, :datetime
    end

    # --- 4: single-worker sweep claim ----------------------------------------------------------
    unless table_exists?(:sla_sweep_state)
      create_table :sla_sweep_state do |t|
        t.datetime :last_run_at
        t.timestamps
      end
    end
  end

  def down
    drop_table :sla_sweep_state, if_exists: true

    remove_column :sla_notification_settings, :last_stale_digest_at, if_exists: true
    remove_column :sla_notification_settings, :stale_threshold_days, if_exists: true

    remove_column :sla_results, :cycle_started_at, if_exists: true

    if index_name_exists?(:sla_notification_logs, 'idx_sla_notification_logs_dedup_uniq')
      remove_index :sla_notification_logs, name: 'idx_sla_notification_logs_dedup_uniq'
    end
    remove_column :sla_notification_logs, :cycle_key, if_exists: true
    unless index_name_exists?(:sla_notification_logs, 'idx_sla_notification_logs_dedup')
      add_index :sla_notification_logs, [:issue_id, :notification_type, :target],
                name: 'idx_sla_notification_logs_dedup'
    end

    change_column_null :sla_notification_logs, :target, true
    change_column_default :sla_notification_logs, :target, nil
  end

  private

  def column_null_false?(table, column)
    col = columns(table).find { |c| c.name == column.to_s }
    col && col.null == false
  end
end
