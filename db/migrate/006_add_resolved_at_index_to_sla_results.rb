# `resolved_at` becomes a filtered column, not just a reported one: the dashboard's definition of
# an OPEN ticket is `resolved_at IS NULL` (Sla::DashboardScope#open_only), and the SLA Met card
# filters a date window against it. Both run on every dashboard load, so the column needs an index
# — migration 004 added it purely as a value to display and left it unindexed.
class AddResolvedAtIndexToSlaResults < ActiveRecord::Migration[6.1]
  def up
    return if index_exists?(:sla_results, :resolved_at)

    add_index :sla_results, :resolved_at
  end

  def down
    remove_index :sla_results, :resolved_at, if_exists: true
  end
end
