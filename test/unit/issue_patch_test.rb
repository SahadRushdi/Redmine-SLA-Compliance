# frozen_string_literal: true

require_relative '../test_helper'

# Event-driven recompute wiring.
# Verifies that RedmineSlaCompliance::Patches::IssuePatch is applied to Issue and that its recompute
# body honours the SLA-module gate. The heavy correctness of the recompute itself lives in
# result_store_test.rb; here we only prove the hook is registered and correctly scoped. Kept fully
# transactional (no after_commit reliance) so nothing persists.
class IssuePatchTest < ActiveSupport::TestCase
  fixtures :projects, :users, :issues, :issue_statuses, :trackers, :enumerations,
           :roles, :members, :member_roles, :enabled_modules

  TRACKER  = 1
  PRIORITY = 6 # High

  setup do
    User.current = User.find(2)
    @base = Time.zone.local(2026, 6, 1, 9, 0, 0)
  end

  def configure_sla(project)
    policy = SlaPolicy.create!(project_id: project.id, enabled: true, coverage_hours: '24x7',
                               first_response_rule: 'either', at_risk_threshold: 80,
                               pause_enabled: true)
    SlaStatusMapping.create!(sla_policy: policy, role: 'created', status_id: 1)
    SlaDefinition.create!(sla_policy: policy, tracker_id: TRACKER, priority_id: PRIORITY,
                          response_seconds: 3600)
    policy
  end

  def make_issue(project)
    issue = Issue.new(project_id: project.id, tracker_id: TRACKER, author_id: 2,
                      priority_id: PRIORITY, status_id: 1, subject: 'patch test')
    issue.save!(validate: false)
    issue.update_column(:created_on, @base)
    issue.reload
  end

  test "the after_commit recompute callback is registered on Issue" do
    assert Issue.included_modules.include?(RedmineSlaCompliance::Patches::IssuePatch),
           'IssuePatch must be included into Issue'
    filters = Issue._commit_callbacks.map(&:filter)
    assert_includes filters, :sla_recalculate_result
  end

  test "recompute runs for an issue whose project has the SLA module enabled" do
    project = Project.find(1)
    project.enable_module!(:sla_compliance)
    configure_sla(project)
    issue = make_issue(project)
    SlaResult.where(issue_id: issue.id).delete_all # start from a clean slate

    assert_difference -> { SlaResult.where(issue_id: issue.id).count }, 1 do
      issue.send(:sla_recalculate_result)
    end
    assert_not_nil SlaResult.find_by(issue_id: issue.id)
  end

  test "recompute is skipped when the project does not have the SLA module enabled" do
    project = Project.find(2)
    project.disable_module!(:sla_compliance) if project.module_enabled?(:sla_compliance)
    configure_sla(project) # policy exists, but the module gate must still short-circuit
    issue = make_issue(project)
    SlaResult.where(issue_id: issue.id).delete_all

    assert_no_difference -> { SlaResult.where(issue_id: issue.id).count } do
      issue.send(:sla_recalculate_result)
    end
  end

  test "a recompute failure never propagates out of the callback" do
    project = Project.find(1)
    project.enable_module!(:sla_compliance)
    issue = make_issue(project)

    Sla::ResultStore.stubs(:recalculate).raises('boom')
    assert_nothing_raised { issue.send(:sla_recalculate_result) }
  end
end
