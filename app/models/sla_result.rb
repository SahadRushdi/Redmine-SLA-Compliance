# frozen_string_literal: true

# Precomputed SLA result cache, one row per issue. Written by the event-driven recompute and the
# time-driven sweep (Phase 3); the dashboard reads only from here, never computing on page load.
class SlaResult < ActiveRecord::Base
  self.table_name = 'sla_results'

  # Plugin-internal classification values — NOT Redmine domain data.
  PRIMARY_STATES = %w[met breached no_sla].freeze
  NO_SLA_REASONS = %w[not_configured not_tracked].freeze

  belongs_to :issue, optional: true
  belongs_to :project, optional: true

  validates :issue_id, presence: true, uniqueness: true
  validates :project_id, presence: true
  validates :primary_state, inclusion: { in: PRIMARY_STATES }
  validates :no_sla_reason, inclusion: { in: NO_SLA_REASONS }, allow_nil: true
  # A reason only makes sense for the no_sla state.
  validate :reason_only_when_no_sla

  scope :met,      -> { where(primary_state: 'met') }
  scope :breached, -> { where(primary_state: 'breached') }
  scope :no_sla,   -> { where(primary_state: 'no_sla') }
  scope :at_risk,  -> { where(at_risk: true) }

  def no_sla?
    primary_state == 'no_sla'
  end

  private

  def reason_only_when_no_sla
    if no_sla_reason.present? && !no_sla?
      errors.add(:no_sla_reason, 'is only valid when primary_state is no_sla')
    end
  end
end
