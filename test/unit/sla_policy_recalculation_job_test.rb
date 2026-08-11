require_relative '../test_helper'

# Step 4.8 — the historical-recalc job wraps Sla::ProjectRecalculator.
class SlaPolicyRecalculationJobTest < ActiveSupport::TestCase
  fixtures :projects, :trackers, :projects_trackers, :issue_statuses, :issues,
           :enumerations, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :journals, :journal_details

  test "perform recalculates the project's cached results" do
    SlaResult.delete_all
    SlaRecalculationState.delete_all
    project = Project.find(1)

    SlaPolicyRecalculationJob.new.perform(project.id)

    issue_ids = project.self_and_descendants.map { |p| p.issues.pluck(:id) }.flatten
    assert issue_ids.any?, 'fixtures must provide issues'
    assert_equal issue_ids.sort, SlaResult.where(issue_id: issue_ids).pluck(:issue_id).sort
    state = SlaRecalculationState.find_by!(project_id: project.id)
    assert_equal 'completed', state.status
    assert_equal issue_ids.size, state.processed_count
  end

  test "a missing project is a no-op" do
    SlaResult.delete_all
    assert_nothing_raised { SlaPolicyRecalculationJob.new.perform(0) }
    assert_equal 0, SlaResult.count
  end

  test "perform records a safe failed state and re-raises the job error" do
    project = Project.find(1)
    state, = SlaRecalculationState.request!(project)
    Sla::ProjectRecalculator.stubs(:run).raises(StandardError, 'private calculation detail')

    assert_raises(StandardError) do
      SlaPolicyRecalculationJob.new.perform(project.id, state.run_token)
    end

    state.reload
    assert_equal 'failed', state.status
    assert_equal I18n.t(:error_sla_recalculation_failed), state.error_message
    assert_not_includes state.error_message, 'private calculation detail'
  end
end
