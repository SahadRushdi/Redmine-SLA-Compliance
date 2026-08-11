# frozen_string_literal: true

# Optional historical recalculation after a policy save. Runs off the request
# path (default :async adapter in-process); idempotent and re-tickable, so a lost job on
# restart is recoverable by saving again with the checkbox ticked.
class SlaPolicyRecalculationJob < ApplicationJob
  queue_as :default

  def perform(project_id, run_token = nil)
    project = Project.find_by(id: project_id)
    return unless project

    state, token = state_for(project, run_token)
    return unless state
    return unless state.start!(token)

    loop do
      count = Sla::ProjectRecalculator.run(
        project,
        progress: ->(processed:, total:) {
          state.record_progress!(token, processed: processed, total: total)
        }
      )
      break unless state.finish_pass!(token, processed: count) == :rerun
    end
  rescue StandardError => e
    Rails.logger.error("[SlaPolicyRecalculationJob] Project #{project_id} failed: #{e.class}: #{e.message}")
    state&.fail!(token, message: I18n.t(:error_sla_recalculation_failed))
    raise
  end

  private

  # Keep direct/legacy invocations with only a project ID functional while every controller path
  # uses the dispatcher and supplies a token.
  def state_for(project, run_token)
    if run_token.present?
      [SlaRecalculationState.find_by(project_id: project.id, run_token: run_token), run_token]
    else
      state, = SlaRecalculationState.request!(project)
      [state, state.run_token]
    end
  end
end
