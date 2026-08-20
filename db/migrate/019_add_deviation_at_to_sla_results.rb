# The deadline from which an open ticket's currently-growing deviation is measured. Persisting the
# projection lets cache readers advance deviation with the clock without rebuilding journals.
class AddDeviationAtToSlaResults < ActiveRecord::Migration[6.1]
  def change
    add_column :sla_results, :deviation_at, :datetime unless column_exists?(:sla_results, :deviation_at)
    add_index :sla_results, :deviation_at unless index_exists?(:sla_results, :deviation_at)
  end
end
