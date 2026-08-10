# frozen_string_literal: true

# A per tracker x priority target set within a policy. Any of the targets may be nil,
# meaning that milestone is not evaluated for this tracker/priority. Targets are stored as
# absolute wall-clock seconds entered directly on the tracker/priority grid.
class SlaDefinition < ActiveRecord::Base
  self.table_name = 'sla_definitions'

  # `update_frequency` is a recurring cadence target rather than a one-shot milestone (see
  # Sla::UpdateFrequencyEvaluator), but it is CONFIGURED identically — same seconds snapshot, same
  # Best Effort flag, same nullable "not tracked" — so it belongs in this list and every generic
  # path below picks it up for free.
  TARGET_TYPES = %w[response workaround resolution update_frequency].freeze

  # Everything that makes up one definition, minus its own identity and owning policy — the exact
  # slice copied when a policy is cloned or prefilled from an ancestor (Sla::PolicyPrefill,
  # SlaPoliciesController#apply_clone_source!). Named once here so adding a target column can't be
  # remembered in one copier and forgotten in the other.
  COPY_ATTRIBUTES = (%w[tracker_id priority_id] +
                     TARGET_TYPES.flat_map do |type|
                       ["#{type}_seconds", "#{type}_best_effort", "#{type}_unit"]
                     end).freeze

  belongs_to :sla_policy

  validates :tracker_id, presence: true
  validates :priority_id, presence: true
  validates :tracker_id, uniqueness: { scope: [:sla_policy_id, :priority_id] }
  validates :response_seconds, :workaround_seconds, :resolution_seconds,
            :update_frequency_seconds,
            numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :response_unit, :workaround_unit, :resolution_unit, :update_frequency_unit,
            inclusion: { in: %w[hours days] }, allow_nil: true

  # True when at least one target is configured — a numeric seconds value OR Best Effort — for
  # this priority (otherwise this row tracks nothing).
  def any_target?
    TARGET_TYPES.any? { |type| public_send("#{type}_seconds").present? || best_effort?(type) }
  end

  def best_effort?(type)
    !!public_send("#{type}_best_effort")
  end
end
