# frozen_string_literal: true

# The original unit snapshot columns were sized for "hours"/"days". "minutes" needs seven
# characters, so widen all four together before the new unit can be persisted.
class ExpandSlaDefinitionUnitColumns < ActiveRecord::Migration[6.1]
  COLUMNS = %i[response_unit workaround_unit resolution_unit update_frequency_unit].freeze

  def up
    COLUMNS.each { |column| change_column :sla_definitions, column, :string, limit: 7 }
  end

  def down
    COLUMNS.each { |column| change_column :sla_definitions, column, :string, limit: 5 }
  end
end
