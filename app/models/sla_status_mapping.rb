# frozen_string_literal: true

# Maps a policy milestone role to a Redmine status ID. `role` is a plugin enum; `status_id` is
# the Redmine reference. Multiple rows per role (a milestone can map to several statuses).
class SlaStatusMapping < ActiveRecord::Base
  self.table_name = 'sla_status_mappings'

  # Plugin-internal milestone roles — NOT Redmine status names.
  ROLES = %w[created work_started resolved pause].freeze

  belongs_to :sla_policy

  validates :role, inclusion: { in: ROLES }
  validates :status_id, presence: true
  validates :status_id, uniqueness: { scope: [:sla_policy_id, :role] }
end
