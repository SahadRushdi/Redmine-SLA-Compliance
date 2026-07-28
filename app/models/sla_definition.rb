# frozen_string_literal: true

# A per tracker x priority target set within a policy. Any of the three targets may be nil,
# meaning that milestone is not evaluated for this tracker/priority. Targets are stored as
# absolute seconds (a snapshot of the chosen sla_target_options value) so SLA math is stable
# even if the admin later edits the lookup.
class SlaDefinition < ActiveRecord::Base
  self.table_name = 'sla_definitions'

  TARGET_TYPES = %w[response workaround resolution].freeze

  # Everything that makes up one definition, minus its own identity and owning policy — the exact
  # slice copied when a policy is cloned or prefilled from an ancestor (Sla::PolicyPrefill,
  # SlaPoliciesController#apply_clone_source!). Named once here so adding a target column can't be
  # remembered in one copier and forgotten in the other.
  COPY_ATTRIBUTES = (%w[tracker_id priority_id] +
                     TARGET_TYPES.flat_map { |type| ["#{type}_seconds", "#{type}_best_effort"] }).freeze

  belongs_to :sla_policy

  validates :tracker_id, presence: true
  validates :priority_id, presence: true
  validates :tracker_id, uniqueness: { scope: [:sla_policy_id, :priority_id] }
  validates :response_seconds, :workaround_seconds, :resolution_seconds,
            numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  # A "1 Business Day"-style ('business'-basis) target option's stored seconds value is only a
  # correct answer when the policy measures elapsed time in working seconds (Coverage Hours =
  # Business Hours) — under 24x7x365 coverage it would silently be read as calendar time. Block
  # the combination outright rather than accept a numerically wrong dashboard value.
  validate :business_basis_targets_require_business_hours_coverage

  # True when at least one target is configured — a numeric seconds value OR Best Effort — for
  # this priority (otherwise this row tracks nothing).
  def any_target?
    TARGET_TYPES.any? { |type| public_send("#{type}_seconds").present? || best_effort?(type) }
  end

  def best_effort?(type)
    !!public_send("#{type}_best_effort")
  end

  private

  def business_basis_targets_require_business_hours_coverage
    return if sla_policy.nil? || sla_policy.business_hours?

    offending = TARGET_TYPES.select { |type| business_basis_target?(type) }
    return if offending.empty?

    labels = offending.map { |type| I18n.t("label_sla_target_#{type}") }.join(', ')
    errors.add(:base, I18n.t(:error_sla_business_basis_requires_business_hours, targets: labels))
  end

  def business_basis_target?(type)
    seconds = public_send("#{type}_seconds")
    return false if seconds.blank?

    SlaTargetOption.exists?(target_type: type, seconds: seconds, basis: 'business')
  end
end
