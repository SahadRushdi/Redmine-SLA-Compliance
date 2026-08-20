# frozen_string_literal: true

module Sla
  # Serializes historical recalculation requests per project and returns the observable state.
  class RecalculationDispatcher
    def self.call(project)
      state, enqueue = SlaRecalculationState.request!(project)
      SlaPolicyRecalculationJob.perform_later(project.id, state.run_token) if enqueue
      state
    rescue StandardError => e
      state&.fail!(state.run_token, message: I18n.t(:error_sla_recalculation_failed))
      raise
    end
  end
end
