# frozen_string_literal: true

# A per tracker x priority target set within a policy. Any of the three targets may be nil,
# meaning that milestone is not evaluated for this tracker/priority. Targets are stored as
# absolute seconds (a snapshot of the chosen sla_target_options value) so SLA math is stable
# even if the admin later edits the lookup.
class SlaDefinition < ActiveRecord::Base
  self.table_name = 'sla_definitions'

  belongs_to :sla_policy

  validates :tracker_id, presence: true
  validates :priority_id, presence: true
  validates :tracker_id, uniqueness: { scope: [:sla_policy_id, :priority_id] }
  validates :response_seconds, :workaround_seconds, :resolution_seconds,
            numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  # True when at least one target is configured (otherwise this row tracks nothing).
  def any_target?
    response_seconds.present? || workaround_seconds.present? || resolution_seconds.present?
  end
end
