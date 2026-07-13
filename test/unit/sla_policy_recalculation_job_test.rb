require_relative '../test_helper'

# Step 4.8 — the historical-recalc job wraps Sla::ProjectRecalculator.
class SlaPolicyRecalculationJobTest < ActiveSupport::TestCase
  fixtures :projects, :trackers, :projects_trackers, :issue_statuses, :issues,
           :enumerations, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :journals, :journal_details

  test "perform recalculates the project's cached results" do
    SlaResult.delete_all
    project = Project.find(1)

    SlaPolicyRecalculationJob.new.perform(project.id)

    issue_ids = project.self_and_descendants.map { |p| p.issues.pluck(:id) }.flatten
    assert issue_ids.any?, 'fixtures must provide issues'
    assert_equal issue_ids.sort, SlaResult.where(issue_id: issue_ids).pluck(:issue_id).sort
  end

  test "a missing project is a no-op" do
    SlaResult.delete_all
    assert_nothing_raised { SlaPolicyRecalculationJob.new.perform(0) }
    assert_equal 0, SlaResult.count
  end
end
