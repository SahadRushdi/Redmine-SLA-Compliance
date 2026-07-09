# frozen_string_literal: true

# One SLA policy per project. Policies are inherited down the project tree (Global Rule 5):
# a project with no policy uses the nearest ancestor's; a disabled policy excludes the project.
class SlaPolicy < ActiveRecord::Base
  self.table_name = 'sla_policies'

  # Plugin-internal enums (modes/rules) — NOT Redmine domain data.
  COVERAGE_HOURS      = %w[24x7 business_hours].freeze
  FIRST_RESPONSE_RULES = %w[first_comment first_status_change either].freeze

  belongs_to :project
  belongs_to :business_calendar, class_name: 'SlaBusinessCalendar', optional: true

  has_many :sla_definitions,     dependent: :destroy
  has_many :sla_status_mappings, dependent: :destroy

  validates :project_id, presence: true, uniqueness: true
  validates :coverage_hours, inclusion: { in: COVERAGE_HOURS }
  validates :first_response_rule, inclusion: { in: FIRST_RESPONSE_RULES }
  validates :at_risk_threshold,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100 }
  # Business Hours coverage requires a calendar to compute against.
  validates :business_calendar_id, presence: true, if: :business_hours?

  scope :enabled, -> { where(enabled: true) }

  def business_hours?
    coverage_hours == 'business_hours'
  end

  # Status IDs configured for a milestone role (created / work_started / resolved / pause).
  def status_ids_for(role)
    sla_status_mappings.where(role: role.to_s).pluck(:status_id)
  end

  # --- Step 1.2: effective-policy resolution -------------------------------------------------
  # Returns the effective SlaPolicy for +project+, walking up the project tree:
  #   * the nearest project (self, then ancestors) that HAS a policy row determines the outcome;
  #   * if that nearest policy is enabled  -> it is the effective policy (may belong to an ancestor);
  #   * if that nearest policy is disabled -> nil (an explicit "SLA off" that stops inheritance);
  #   * if no ancestor has a policy        -> nil.
  # One query loads every candidate policy; no per-level N+1.
  def self.effective_for(project)
    return nil unless project

    branch = project.self_and_ancestors.to_a            # root -> self (nested-set order)
    policies = where(project_id: branch.map(&:id)).index_by(&:project_id)

    branch.reverse_each do |proj|                       # nearest (self) first
      policy = policies[proj.id]
      next unless policy
      return policy.enabled? ? policy : nil
    end
    nil
  end
end
