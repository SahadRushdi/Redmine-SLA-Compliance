# frozen_string_literal: true

# One-row singleton tracking when the at-risk/stale sweep last ran, so multiple app-server worker
# processes — each running their own copy of RedmineSlaCompliance::SweepScheduler — don't all
# perform the full sweep every interval. Without this, N workers means N x the recompute load for
# no correctness benefit (duplicate sweeps were already safe once the notification dedup was
# fixed; this just removes the wasted work, per Global Rule 4 — "do not break or slow Redmine").
class SlaSweepState < ActiveRecord::Base
  self.table_name = 'sla_sweep_state'

  SINGLETON_ID = 1

  # Atomically claim a sweep run: succeeds (returns true) only if no other process has already
  # claimed one within the current interval. A conditional `UPDATE ... WHERE` — the same
  # DB-constraint pattern as `SlaNotificationSetting.claim_stale_digest_window!` — so this is safe
  # under concurrent callers across any number of processes with no distributed lock needed.
  def self.claim_run!(now:, interval_minutes:)
    ensure_row!
    cutoff = now - (interval_minutes * 60)
    claimed_rows = where(id: SINGLETON_ID)
                   .where('last_run_at IS NULL OR last_run_at <= ?', cutoff)
                   .update_all(last_run_at: now)
    claimed_rows == 1
  end

  # Creates the singleton row on first use. Racing to create it is harmless: at most one caller
  # wins the insert, everyone else hits the (rescued) uniqueness of the primary key.
  def self.ensure_row!
    create!(id: SINGLETON_ID) unless where(id: SINGLETON_ID).exists?
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
