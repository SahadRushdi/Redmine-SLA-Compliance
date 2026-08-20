# Persists one observable historical-recalculation run per project. Database state is used rather
# than Rails.cache because Redmine's default cache may be disabled or process-local while the job
# and the polling request can run in different processes.
class CreateSlaRecalculationStates < ActiveRecord::Migration[6.1]
  def up
    unless table_exists?(:sla_recalculation_states)
      create_table :sla_recalculation_states do |t|
        t.integer :project_id, null: false
        t.string :run_token, null: false, limit: 64
        t.string :status, null: false, default: 'queued', limit: 20
        t.integer :total_count, null: false, default: 0
        t.integer :processed_count, null: false, default: 0
        t.boolean :rerun_requested, null: false, default: false
        t.datetime :started_at
        t.datetime :finished_at
        t.string :error_message, limit: 255
        t.timestamps
      end
    end

    add_index :sla_recalculation_states, :project_id, unique: true unless
      index_exists?(:sla_recalculation_states, :project_id, unique: true)
    add_index :sla_recalculation_states, :run_token, unique: true unless
      index_exists?(:sla_recalculation_states, :run_token, unique: true)
    add_foreign_key :sla_recalculation_states, :projects, column: :project_id, on_delete: :cascade unless
      foreign_key_exists?(:sla_recalculation_states, :projects, column: :project_id)
  end

  def down
    drop_table :sla_recalculation_states, if_exists: true
  end
end
