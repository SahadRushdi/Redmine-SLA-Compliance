# Step 6.3 (Created-vs-Resolved trend chart) needs a resolution timestamp per issue, but
# `sla_results` never persisted one — `ResultClassifier#closed_at` (first transition into a
# `resolved`-role status, per the effective policy's `sla_status_mappings`) was computed
# internally on every classification and then thrown away, since nothing outside the engine
# needed it before this. The dashboard reads only from this cache (Global Rule 4), so the value
# has to live here rather than being recomputed per request.
#
# Nullable, no backfill: existing rows populate `resolved_at` the next time they're recomputed
# (the event-driven hook, the sweep, or the Step 3.2 historical-recalc checkbox) — the same
# lazy-population behavior every other engine-added cache column has had in this table.
class AddResolvedAtToSlaResults < ActiveRecord::Migration[6.1]
  def up
    unless column_exists?(:sla_results, :resolved_at)
      add_column :sla_results, :resolved_at, :datetime
    end
  end

  def down
    remove_column :sla_results, :resolved_at, if_exists: true
  end
end
