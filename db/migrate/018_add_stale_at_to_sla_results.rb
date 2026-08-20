class AddStaleAtToSlaResults < ActiveRecord::Migration[6.1]
  def change
    add_column :sla_results, :stale_at, :datetime unless column_exists?(:sla_results, :stale_at)
    add_index :sla_results, :stale_at unless index_exists?(:sla_results, :stale_at)
  end
end
