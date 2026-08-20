# frozen_string_literal: true

# Precomputed SLA result cache, one row per issue. Written by the event-driven recompute and the
# one-off live transition jobs; the dashboard reads only from here, never rebuilding timelines.
class SlaResult < ActiveRecord::Base
  self.table_name = 'sla_results'

  # Plugin-internal classification values — NOT Redmine domain data.
  PRIMARY_STATES = %w[met breached no_sla].freeze
  NO_SLA_REASONS = %w[not_configured not_tracked].freeze

  include Sla::EffectiveState

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

  # The engine's elapsed fields keep advancing while a milestone is pending so breach and at-risk
  # classification remain correct. Dashboard readers must use these completion-aware accessors
  # instead of exposing those running clocks as though the milestone had already happened.
  def completed_response_seconds
    response_seconds if first_response_at.present?
  end

  def completed_resolution_seconds
    resolution_seconds if resolved_at.present?
  end

  private

  def reason_only_when_no_sla
    if no_sla_reason.present? && !no_sla?
      errors.add(:no_sla_reason, 'is only valid when primary_state is no_sla')
    end
  end
end
