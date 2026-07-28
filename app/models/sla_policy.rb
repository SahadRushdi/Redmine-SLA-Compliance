# frozen_string_literal: true

# One SLA policy per project. Policies are inherited down the project tree (Global Rule 5):
# a project with no policy uses the nearest ancestor's; a disabled policy excludes the project.
#
# A row carries two separable things — the enabled DECISION and the CONFIGURATION — and
# `inherits_config` says whether it owns the latter. A subproject can therefore switch SLA on or
# off for itself with a lightweight decision-only row while still following the parent's
# configuration; see `effective_for` and migration 005.
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

  # True for a LIGHTWEIGHT row: one that carries only the enabled DECISION for its project and
  # inherits every configuration field (coverage, calendar, first-response rule, at-risk threshold,
  # pause, plus definitions and status mappings) from the nearest self-defining ancestor. Written
  # by the tri-state control on the settings tab; see migration 005.
  def inherits_config?
    !!inherits_config
  end

  # --- Step 1.2: effective-policy resolution -------------------------------------------------
  # Returns the effective SlaPolicy for +project+, walking up the project tree. A policy row
  # carries two separable things — an enabled DECISION and a CONFIGURATION — and inheritance
  # resolves them independently (Global Rule 5's tri-state):
  #
  #   * the nearest project (self, then ancestors) with a row makes the enabled decision;
  #   * disabled  -> nil (an explicit "SLA off" that stops inheritance, as it always has);
  #   * enabled and self-defining     -> that row IS the effective policy;
  #   * enabled and inherits_config   -> the decision stands, but the configuration comes from the
  #     nearest SELF-DEFINING ancestor (whose own enabled flag is deliberately ignored — the
  #     descendant has explicitly overridden it, which is the whole point of a lightweight row);
  #   * no row anywhere, or a lightweight row with no self-defining ancestor to configure it
  #     (nothing to measure against) -> nil.
  #
  # One query loads every candidate policy; no per-level N+1.
  def self.effective_for(project)
    ordered  = nearest_first_policies(project)
    decision = ordered.first
    return nil if decision.nil? || !decision.enabled?
    return decision unless decision.inherits_config?

    ordered.find { |policy| !policy.inherits_config? }
  end

  # Where the policy shown/edited on +project+'s SLA Policy tab actually comes from — distinct
  # from `effective_for` (which only cares whether the nearest policy is enabled, per Global
  # Rule 5): this ignores enabled/disabled entirely and returns [source_project, policy] for the
  # nearest project (self, then ancestors) that HAS A ROW AT ALL. The UI needs this to decide
  # whether to render an editable form (own row, any enabled state) or a read-only "inherited
  # from X" banner (nearest row belongs to an ancestor).
  def self.source_for(project)
    nearest_policy_with(project) { |_policy| true }
  end

  # The row whose CONFIGURATION governs +project+ — the nearest self-defining one, skipping past
  # any lightweight rows (which have nothing to display). This, not `source_for`, is what the
  # settings tab's inherited banner renders: a project holding only a lightweight row still has
  # no configuration of its own and must keep showing the ancestor's.
  def self.config_source_for(project)
    nearest_policy_with(project) { |policy| !policy.inherits_config? }
  end

  # This project's OWN enablement decision, ignoring the tree: :inherit (no row of its own, so the
  # ancestor's decision applies), :enabled or :disabled. Drives the tri-state control's selection.
  def self.enablement_for(project)
    policy = find_by(project_id: project&.id)
    return :inherit if policy.nil?

    policy.enabled? ? :enabled : :disabled
  end

  # [project, policy] pairs for every policy row on the branch root..self, ordered NEAREST (self)
  # FIRST. Single query — the one traversal every resolver above shares, so there is no second
  # tree-walk implementation to keep in sync. Pairs rather than bare policies so `source_for` can
  # name the owning project without a `policy.project` lookup per candidate.
  def self.nearest_first_owned_policies(project)
    return [] unless project

    branch = project.self_and_ancestors.to_a            # root -> self (nested-set order)
    policies = where(project_id: branch.map(&:id)).index_by(&:project_id)
    branch.reverse.filter_map { |proj| [proj, policies[proj.id]] if policies[proj.id] }
  end
  private_class_method :nearest_first_owned_policies

  def self.nearest_first_policies(project)
    nearest_first_owned_policies(project).map(&:last)
  end
  private_class_method :nearest_first_policies

  def self.nearest_policy_with(project, &matcher)
    nearest_first_owned_policies(project).find { |_proj, policy| matcher.call(policy) } || [nil, nil]
  end
  private_class_method :nearest_policy_with

  # Projects +user+ may open the SLA dashboard on: active, visible, SLA-module-enabled, with an
  # ENABLED effective policy, and view_sla_dashboard-permitted (role or Step 5.1 allow-list).
  # +base_scope+ narrows the candidates before the per-project checks run — the project-level
  # dashboard passes `@project.self_and_descendants` so a subtree scan never touches unrelated
  # projects; the top-level (cross-project) dashboard leaves it at the full active+module-enabled
  # universe.
  def self.enabled_projects_for(user, base_scope: Project.active.has_module(:sla_compliance))
    return [] if user.nil? || !user.logged?

    base_scope.visible(user).to_a.select do |project|
      user.allowed_to?(:view_sla_dashboard, project) && effective_for(project).present?
    end
  end
end
