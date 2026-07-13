# frozen_string_literal: true

# Optional historical recalculation after a policy save. Runs off the request
# path (default :async adapter in-process); idempotent and re-tickable, so a lost job on
# restart is recoverable by saving again with the checkbox ticked.
class SlaPolicyRecalculationJob < ApplicationJob
  queue_as :default

  def perform(project_id)
    project = Project.find_by(id: project_id)
    return unless project

    Sla::ProjectRecalculator.run(project)
  end
end
