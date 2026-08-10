# Remembers how each direct duration was entered so "72 Hours" remains "72 Hours" after reload
# instead of being reformatted as "3 Days". Existing targets fall back to a readable derived unit.
class AddUnitsToSlaDefinitions < ActiveRecord::Migration[6.1]
  def change
    %w[response workaround resolution update_frequency].each do |target_type|
      add_column :sla_definitions, "#{target_type}_unit", :string, limit: 5
    end
  end
end
