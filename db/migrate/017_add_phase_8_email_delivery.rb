# frozen_string_literal: true

class AddPhase8EmailDelivery < ActiveRecord::Migration[6.1]
  class MigrationSetting < ActiveRecord::Base
    self.table_name = 'sla_notification_settings'
    serialize :at_risk_email_recipients, JSON
    serialize :stale_email_recipients, JSON
  end

  class MigrationEmailAddress < ActiveRecord::Base
    self.table_name = 'email_addresses'
  end

  def up
    unless table_exists?(:sla_notification_recipients)
      create_table :sla_notification_recipients do |t|
        t.bigint :sla_notification_setting_id, null: false
        t.string :channel, null: false, limit: 20
        t.integer :user_id, null: false
        t.timestamps
      end
    end
    unless index_name_exists?(:sla_notification_recipients, 'idx_sla_notification_recipients_unique')
      add_index :sla_notification_recipients,
                %i[sla_notification_setting_id channel user_id], unique: true,
                name: 'idx_sla_notification_recipients_unique'
    end
    add_index :sla_notification_recipients, :user_id unless
      index_exists?(:sla_notification_recipients, :user_id)
    unless foreign_key_exists?(:sla_notification_recipients, :sla_notification_settings,
                               column: :sla_notification_setting_id)
      add_foreign_key :sla_notification_recipients, :sla_notification_settings,
                      column: :sla_notification_setting_id, on_delete: :cascade
    end

    add_column :sla_notification_digest_states, :last_at_risk_digest_at, :datetime unless
      column_exists?(:sla_notification_digest_states, :last_at_risk_digest_at)
    delivery_state_added = !column_exists?(:sla_notification_logs, :delivery_state)
    add_column :sla_notification_logs, :delivery_state, :string, null: false,
               default: 'pending', limit: 12 if delivery_state_added
    add_column :sla_notification_logs, :failure_message, :string, limit: 255 unless
      column_exists?(:sla_notification_logs, :failure_message)
    add_index :sla_notification_logs, %i[notification_type delivery_state],
              name: 'idx_sla_notification_logs_delivery' unless
      index_name_exists?(:sla_notification_logs, 'idx_sla_notification_logs_delivery')

    migrate_legacy_recipients!
    if delivery_state_added
      execute "UPDATE sla_notification_logs SET delivery_state = 'sent' WHERE sent_at IS NOT NULL"
      execute "UPDATE sla_notification_logs SET delivery_state = 'failed', " \
              "failure_message = 'Pre-Phase-8 claim was not deliverable' " \
              "WHERE sent_at IS NULL AND notification_type IN ('at_risk', 'stale')"
    end
  end

  def down
    remove_index :sla_notification_logs, name: 'idx_sla_notification_logs_delivery' if
      index_name_exists?(:sla_notification_logs, 'idx_sla_notification_logs_delivery')
    remove_column :sla_notification_logs, :failure_message if
      column_exists?(:sla_notification_logs, :failure_message)
    remove_column :sla_notification_logs, :delivery_state if
      column_exists?(:sla_notification_logs, :delivery_state)
    remove_column :sla_notification_digest_states, :last_at_risk_digest_at if
      column_exists?(:sla_notification_digest_states, :last_at_risk_digest_at)
    drop_table :sla_notification_recipients, if_exists: true
  end

  private

  def migrate_legacy_recipients!
    MigrationSetting.find_each do |setting|
      { 'at_risk' => setting.at_risk_email_recipients,
        'stale' => setting.stale_email_recipients }.each do |channel, addresses|
        Array(addresses).reject(&:blank?).each do |address|
          matches = MigrationEmailAddress.where('LOWER(address) = ?', address.to_s.downcase)
          raise ActiveRecord::MigrationError,
                "Cannot map SLA notification recipient #{address.inspect} to exactly one Redmine user" unless matches.one?

          execute <<~SQL.squish
            INSERT INTO sla_notification_recipients
              (sla_notification_setting_id, channel, user_id, created_at, updated_at)
            SELECT #{setting.id.to_i}, #{connection.quote(channel)}, #{matches.first.user_id.to_i},
                   #{connection.quote(Time.current)}, #{connection.quote(Time.current)}
            WHERE NOT EXISTS (
              SELECT 1 FROM sla_notification_recipients
              WHERE sla_notification_setting_id = #{setting.id.to_i}
                AND channel = #{connection.quote(channel)}
                AND user_id = #{matches.first.user_id.to_i}
            )
          SQL
        end
      end
    end
  end
end
