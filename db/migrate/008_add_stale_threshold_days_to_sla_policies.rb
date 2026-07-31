# The dashboard's Stale card threshold, per project (Step 6.2a).
#
# It lives on `sla_policies` rather than in the plugin settings hash because "how long without
# activity is too long" is a per-customer answer, and this table is already the per-project,
# parent→child-inherited configuration surface (Global Rule 5). Putting it here means inheritance,
# the tri-state lightweight row, the clone/prefill copiers and the settings tab's fork-on-save all
# apply to it for free — no second inheritance mechanism to keep in step with the first.
#
# NULLABLE, no default, deliberately: nil means "not set here", which is what makes the field
# clearable and what lets a subproject fall back to its parent's number
# (SlaPolicy.stale_threshold_days_for). A DB default would make every project look like it had
# chosen a value nobody chose — the exact defect this whole step exists to fix.
class AddStaleThresholdDaysToSlaPolicies < ActiveRecord::Migration[6.1]
  def up
    return if column_exists?(:sla_policies, :stale_threshold_days)

    add_column :sla_policies, :stale_threshold_days, :integer
  end

  def down
    remove_column :sla_policies, :stale_threshold_days, if_exists: true
  end
end
