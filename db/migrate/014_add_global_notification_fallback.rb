# frozen_string_literal: true

class AddGlobalNotificationFallback < ActiveRecord::Migration[6.1]
  class MigrationNotificationSetting < ActiveRecord::Base
    self.table_name = 'sla_notification_settings'
  end

  class MigrationDigestState < ActiveRecord::Base
    self.table_name = 'sla_notification_digest_states'
  end

  def up
    add_column :sla_notification_settings, :scope_key, :string, limit: 64 unless
      column_exists?(:sla_notification_settings, :scope_key)

    MigrationNotificationSetting.reset_column_information
    MigrationNotificationSetting.where(scope_key: nil).find_each do |setting|
      setting.update_columns(scope_key: "project:#{setting.project_id}")
    end

    change_column_null :sla_notification_settings, :scope_key, false
    change_column_null :sla_notification_settings, :project_id, true
    add_index :sla_notification_settings, :scope_key, unique: true,
              name: 'idx_sla_notification_settings_scope' unless
      index_name_exists?(:sla_notification_settings, 'idx_sla_notification_settings_scope')

    unless table_exists?(:sla_notification_digest_states)
      create_table :sla_notification_digest_states do |t|
        t.integer :project_id, null: false
        t.datetime :last_stale_digest_at
        t.timestamps
      end
      add_index :sla_notification_digest_states, :project_id, unique: true,
                name: 'idx_sla_notification_digest_states_project'
      add_foreign_key :sla_notification_digest_states, :projects, column: :project_id,
                      on_delete: :cascade
    end

    MigrationDigestState.reset_column_information
    MigrationNotificationSetting.where.not(project_id: nil)
                                .where.not(last_stale_digest_at: nil).find_each do |setting|
      state = MigrationDigestState.find_or_initialize_by(project_id: setting.project_id)
      state.last_stale_digest_at = setting.last_stale_digest_at
      state.save!
    end
  end

  def down
    if table_exists?(:sla_notification_digest_states)
      MigrationDigestState.reset_column_information
      MigrationDigestState.find_each do |state|
        MigrationNotificationSetting.where(project_id: state.project_id)
                                    .update_all(last_stale_digest_at: state.last_stale_digest_at)
      end
    end
    MigrationNotificationSetting.where(scope_key: 'global').delete_all
    change_column_null :sla_notification_settings, :project_id, false
    remove_index :sla_notification_settings, name: 'idx_sla_notification_settings_scope' if
      index_name_exists?(:sla_notification_settings, 'idx_sla_notification_settings_scope')
    remove_column :sla_notification_settings, :scope_key if
      column_exists?(:sla_notification_settings, :scope_key)
    drop_table :sla_notification_digest_states, if_exists: true
  end
end
