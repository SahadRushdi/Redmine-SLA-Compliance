# frozen_string_literal: true

class SlaNotificationRecipient < ActiveRecord::Base
  self.table_name = 'sla_notification_recipients'

  CHANNELS = %w[at_risk stale].freeze

  belongs_to :sla_notification_setting
  belongs_to :user

  validates :channel, inclusion: { in: CHANNELS }
  validates :user_id, uniqueness: { scope: %i[sla_notification_setting_id channel] }
end
