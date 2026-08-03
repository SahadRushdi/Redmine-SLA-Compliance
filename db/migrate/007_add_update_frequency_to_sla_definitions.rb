# Update Frequency — a FOURTH SLA target, alongside Response / Workaround / Resolution.
#
# Unlike those three (each "time from clock-start to one milestone event"), this one is a
# recurring cadence check: a real human status comment must land at least every N seconds for as
# long as the ticket is open. A ticket nowhere near its Resolution deadline still breaches if it
# goes quiet for longer than this target (see Sla::UpdateFrequencyEvaluator).
#
# It is stored exactly like the other three — per tracker × priority on `sla_definitions`, a
# nullable seconds snapshot (nil = not tracked for that priority) plus a Best Effort flag, never
# an FK back to `sla_target_options` (see SlaDefinition's own comment on snapshotting). That is
# what lets every generic path — SlaDefinition::COPY_ATTRIBUTES, the clone/prefill copiers, the
# controller's target whitelisting, the settings form — pick it up from TARGET_TYPES alone.
#
# `sla_results.update_frequency_seconds` caches the LARGEST quiet gap the engine observed, the
# figure the breach is judged on, so the dashboard keeps reading only from the cache (Global
# Rule 4). Nullable with no backfill, like every engine-added cache column before it (migration
# 004): existing rows populate on their next recompute.
class AddUpdateFrequencyToSlaDefinitions < ActiveRecord::Migration[6.1]
  def up
    unless column_exists?(:sla_definitions, :update_frequency_seconds)
      add_column :sla_definitions, :update_frequency_seconds, :integer # nullable = skipped
    end
    unless column_exists?(:sla_definitions, :update_frequency_best_effort)
      add_column :sla_definitions, :update_frequency_best_effort, :boolean,
                 null: false, default: false
    end
    unless column_exists?(:sla_results, :update_frequency_seconds)
      add_column :sla_results, :update_frequency_seconds, :integer
    end
  end

  def down
    remove_column :sla_results, :update_frequency_seconds, if_exists: true
    remove_column :sla_definitions, :update_frequency_best_effort, if_exists: true
    remove_column :sla_definitions, :update_frequency_seconds, if_exists: true
  end
end
