# Target seconds already live on sla_definitions, so removing the reusable catalogs loses no policy
# target values. Business-hours policies are normalized to wall-clock mode before their calendar
# reference and the calendar table are removed.
class RemoveTargetCatalogsAndBusinessCalendars < ActiveRecord::Migration[6.1]
  def up
    execute "UPDATE sla_policies SET coverage_hours = '24x7' WHERE coverage_hours <> '24x7'"

    if column_exists?(:sla_policies, :business_calendar_id)
      if foreign_key_exists?(:sla_policies, column: :business_calendar_id)
        remove_foreign_key :sla_policies, column: :business_calendar_id
      end
      remove_index :sla_policies, :business_calendar_id if index_exists?(:sla_policies, :business_calendar_id)
      remove_column :sla_policies, :business_calendar_id
    end

    drop_table :sla_target_options, if_exists: true
    drop_table :sla_business_calendars, if_exists: true
  end

  def down
    create_table :sla_business_calendars do |t|
      t.string :name, null: false
      t.text :working_days
      t.string :work_start_time
      t.string :work_end_time
      t.text :holidays
      t.timestamps
    end unless table_exists?(:sla_business_calendars)
    add_index :sla_business_calendars, :name, unique: true unless index_exists?(:sla_business_calendars, :name)

    create_table :sla_target_options do |t|
      t.string :target_type, null: false, limit: 20
      t.string :code, null: false, limit: 50
      t.string :label, null: false, limit: 100
      t.integer :seconds
      t.integer :position, null: false, default: 1
      t.boolean :best_effort, null: false, default: false
      t.string :basis, null: false, default: 'calendar', limit: 20
      t.timestamps
    end unless table_exists?(:sla_target_options)
    add_index :sla_target_options, :target_type unless index_exists?(:sla_target_options, :target_type)
    unless index_exists?(:sla_target_options, %i[target_type code])
      add_index :sla_target_options, %i[target_type code], unique: true
    end

    unless column_exists?(:sla_policies, :business_calendar_id)
      add_column :sla_policies, :business_calendar_id, :integer
      add_index :sla_policies, :business_calendar_id
      add_foreign_key :sla_policies, :sla_business_calendars, column: :business_calendar_id
    end
  end
end
