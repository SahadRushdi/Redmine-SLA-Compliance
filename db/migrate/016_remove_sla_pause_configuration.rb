# frozen_string_literal: true

class RemoveSlaPauseConfiguration < ActiveRecord::Migration[6.1]
  def up
    execute "DELETE FROM sla_status_mappings WHERE role = 'pause'"
    remove_column :sla_policies, :pause_enabled if column_exists?(:sla_policies, :pause_enabled)
  end

  def down
    add_column :sla_policies, :pause_enabled, :boolean, null: false, default: true unless
      column_exists?(:sla_policies, :pause_enabled)
  end
end
