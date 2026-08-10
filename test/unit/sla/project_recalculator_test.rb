# frozen_string_literal: true

require_relative '../../test_helper'

# Historical / project recalc.
# Done when: "With the tick, old tickets recompute; without it, they don't." Uses the fixture
# project chain ecookbook(1) -> private-child(5) -> project6(6) so inheritance is exercised.
class Sla::ProjectRecalculatorTest < ActiveSupport::TestCase
  fixtures :projects, :users, :issues, :issue_statuses, :trackers, :enumerations,
           :roles, :members, :member_roles

  TRACKER  = 1
  PRIORITY = 6 # High

  setup do
    User.current = User.find(2)
    @base = Time.zone.local(2026, 6, 1, 9, 0, 0)
    @root  = Project.find(1)
    @child = Project.find(5)

    @policy = SlaPolicy.create!(project_id: @root.id, enabled: true, coverage_hours: '24x7',
                                first_response_rule: 'either', at_risk_threshold: 80,
                                pause_enabled: true)
    SlaStatusMapping.create!(sla_policy: @policy, role: 'created', status_id: 1)
    SlaDefinition.create!(sla_policy: @policy, tracker_id: TRACKER, priority_id: PRIORITY,
                          response_seconds: 3600)
    Sla::LiveTransitionScheduler.stubs(:call)
  end

  def make_issue(project)
    issue = Issue.new(project_id: project.id, tracker_id: TRACKER, author_id: 2,
                      priority_id: PRIORITY, status_id: 1, subject: 'recalc test')
    issue.save!(validate: false)
    issue.update_column(:created_on, @base)
    issue.reload
  end

  test "run recomputes every issue in the project and returns the count" do
    issues = Array.new(3) { make_issue(@root) }
    assert_equal 0, SlaResult.where(issue_id: issues.map(&:id)).count

    count = Sla::ProjectRecalculator.run(@root, include_descendants: false, now: @base + 1800)

    assert_operator count, :>=, 3
    issues.each do |issue|
      row = SlaResult.find_by(issue_id: issue.id)
      assert_not_nil row, "expected a cached result for issue ##{issue.id}"
      assert_equal 'met', row.primary_state
    end
  end

  test "run includes descendant projects that inherit the policy" do
    root_issue  = make_issue(@root)
    child_issue = make_issue(@child) # inherits @policy via effective_for

    Sla::ProjectRecalculator.run(@root, include_descendants: true, now: @base + 1800)

    assert_not_nil SlaResult.find_by(issue_id: root_issue.id)
    child_row = SlaResult.find_by(issue_id: child_issue.id)
    assert_not_nil child_row, 'descendant issue must be recalculated'
    assert_equal 'met', child_row.primary_state
  end

  test "saving or updating a policy alone does not recompute (forward-only default)" do
    issues = Array.new(2) { make_issue(@root) }

    # Merely creating/updating a policy must not touch the cache — no recalc callback on SlaPolicy.
    @policy.update!(at_risk_threshold: 90)

    assert_equal 0, SlaResult.where(issue_id: issues.map(&:id)).count,
                 'old tickets must NOT recompute without an explicit ProjectRecalculator.run'

    Sla::ProjectRecalculator.run(@root, include_descendants: false, now: @base + 1800)
    assert_equal issues.size, SlaResult.where(issue_id: issues.map(&:id)).count
  end
end
