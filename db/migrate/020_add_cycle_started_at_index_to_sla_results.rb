# The SLA Trend card and Created series filter the cache by the configured Created/reopen milestone
# timestamp. Keep that period query indexed for large cross-project dashboards.
class AddCycleStartedAtIndexToSlaResults < ActiveRecord::Migration[6.1]
  def up
    add_index :sla_results, :cycle_started_at unless index_exists?(:sla_results, :cycle_started_at)
  end

  def down
    remove_index :sla_results, :cycle_started_at if index_exists?(:sla_results, :cycle_started_at)
  end
end
