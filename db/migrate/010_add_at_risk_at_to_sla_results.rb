# Stores the projected instant at which an open ticket enters its at-risk window. Dashboard readers
# compare this indexed value with the current time, giving live state without a recurring sweep.
class AddAtRiskAtToSlaResults < ActiveRecord::Migration[6.1]
  def change
    add_column :sla_results, :at_risk_at, :datetime unless column_exists?(:sla_results, :at_risk_at)
    add_index :sla_results, :at_risk_at unless index_exists?(:sla_results, :at_risk_at)
  end
end
