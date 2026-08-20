# Remembers how each direct duration was entered so "72 Hours" remains "72 Hours" after reload
# instead of being reformatted as "3 Days". Existing targets fall back to a readable derived unit.
class AddUnitsToSlaDefinitions < ActiveRecord::Migration[6.1]
  def change
    %w[response workaround resolution update_frequency].each do |target_type|
      column = "#{target_type}_unit"
      add_column :sla_definitions, column, :string, limit: 5 unless column_exists?(:sla_definitions, column)
    end
  end
end
