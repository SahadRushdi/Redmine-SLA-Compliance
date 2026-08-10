# Update SLA Compliance Settings page to save Tracker type and show Clone Project in the drop-down list
class AddTrackerSelectionAndCloneSourceToSlaPolicies < ActiveRecord::Migration[6.1]
  def up
    add_column :sla_policies, :selected_tracker_ids, :text unless
      column_exists?(:sla_policies, :selected_tracker_ids)
    add_column :sla_policies, :cloned_from_project_id, :integer unless
      column_exists?(:sla_policies, :cloned_from_project_id)
  end

  def down
    remove_column :sla_policies, :selected_tracker_ids, if_exists: true
    remove_column :sla_policies, :cloned_from_project_id, if_exists: true
  end
end
