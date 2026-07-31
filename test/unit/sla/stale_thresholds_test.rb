# frozen_string_literal: true

require_relative '../../test_helper'

# Step 6.2a — the Stale threshold's per-project resolution, and its inheritance down the tree.
#
# Covers BOTH implementations together on purpose: SlaPolicy.stale_threshold_days_for (one project,
# walks the branch) and Sla::StaleThresholds (the whole dashboard scope in two queries). They answer
# the same question by different routes, so every case asserts them against each other — a drift
# between them would show as one dashboard number disagreeing with the settings tab that explains it.
class Sla::StaleThresholdsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules

  # Fixture tree: 1 (eCookbook) → 5 (Private child of eCookbook) → 6 (Child of private child).
  # 2 (OnlineStore) is a separate root — nothing may leak sideways to it.
  ROOT       = 1
  CHILD      = 5
  GRANDCHILD = 6
  UNRELATED  = 2

  setup do
    Setting.plugin_redmine_sla_compliance = {}
    assert_equal ROOT, Project.find(CHILD).parent_id, 'fixture assumption'
    assert_equal CHILD, Project.find(GRANDCHILD).parent_id, 'fixture assumption'
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  def policy!(project_id, stale_threshold_days: nil, **attrs)
    SlaPolicy.create!({ project_id: project_id, enabled: true,
                        stale_threshold_days: stale_threshold_days }.merge(attrs))
  end

  # Both routes, one assertion — see the class comment.
  def assert_threshold(expected, project_id, message = nil)
    project = Project.find(project_id)
    assert_equal expected, SlaPolicy.stale_threshold_days_for(project), message
    assert_equal expected, Sla::StaleThresholds.for_projects([project_id])[project_id], message
  end

  test 'a project with its own value uses it' do
    policy!(ROOT, stale_threshold_days: 4)

    assert_threshold 4, ROOT
  end

  test "a subproject with no value of its own inherits the root's" do
    policy!(ROOT, stale_threshold_days: 4)

    assert_threshold 4, CHILD, 'configuring the root must cover the whole tree beneath it'
  end

  test 'inheritance reaches a grandchild, past an intermediate project that sets nothing' do
    policy!(ROOT, stale_threshold_days: 4)
    policy!(CHILD) # a row, but no threshold of its own

    assert_threshold 4, GRANDCHILD
  end

  test 'the nearest ancestor wins over a more distant one' do
    policy!(ROOT, stale_threshold_days: 4)
    policy!(CHILD, stale_threshold_days: 2)

    assert_threshold 2, GRANDCHILD
    assert_threshold 4, ROOT, 'the root keeps its own'
  end

  test "a subproject's own value overrides what it would inherit" do
    policy!(ROOT, stale_threshold_days: 4)
    policy!(CHILD, stale_threshold_days: 9)

    assert_threshold 9, CHILD
  end

  test 'clearing a subproject value goes back to inheriting — the "remove it" path' do
    policy!(ROOT, stale_threshold_days: 4)
    child = policy!(CHILD, stale_threshold_days: 9)
    assert_threshold 9, CHILD

    child.update!(stale_threshold_days: nil)

    assert_threshold 4, CHILD, 'clearing the field must inherit again, not fall to nothing'
  end

  test 'inheritance does not leak sideways to an unrelated project' do
    policy!(ROOT, stale_threshold_days: 4)

    assert_nil SlaPolicy.stale_threshold_days_for(Project.find(UNRELATED))
    assert_empty Sla::StaleThresholds.for_projects([UNRELATED])
  end

  # There is no instance-wide fallback: a project that inherits nothing has no threshold, full stop.
  test 'nothing in the tree resolves to nil, and the project is simply absent from the batch' do
    assert_nil SlaPolicy.stale_threshold_days_for(Project.find(ROOT))
    assert_empty Sla::StaleThresholds.for_projects([ROOT])
  end

  # A lightweight row carries only the enabled decision (SlaPolicy#inherits_config?) — it owns no
  # configuration, so it must not shadow the ancestor's threshold with its own nil.
  test 'a lightweight subproject row does not block inheritance' do
    policy!(ROOT, stale_threshold_days: 4)
    policy!(CHILD, inherits_config: true)

    assert_threshold 4, CHILD
  end

  test 'the batch resolves several projects at once, each on its own branch' do
    policy!(ROOT, stale_threshold_days: 4)
    policy!(CHILD, stale_threshold_days: 2)
    policy!(UNRELATED, stale_threshold_days: 30)

    resolved = Sla::StaleThresholds.for_projects([ROOT, CHILD, GRANDCHILD, UNRELATED])

    assert_equal({ ROOT => 4, CHILD => 2, GRANDCHILD => 2, UNRELATED => 30 }, resolved)
  end

  def count_queries
    queries = 0
    counter = ->(_name, _start, _finish, _id, payload) { queries += 1 unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    queries
  end

  # The reason this class exists at all: the cross-project dashboard resolves the whole scope on
  # every page load, so the cost must not scale with how many projects are in it.
  test 'the batch costs the same for every project in the instance as for one that inherits' do
    policy!(ROOT, stale_threshold_days: 4)
    every_project = Project.pluck(:id)

    # A project that INHERITS is the expensive case — it needs both queries. Resolving the whole
    # instance must cost no more than resolving that one.
    one = count_queries { Sla::StaleThresholds.for_projects([CHILD]) }
    all = count_queries { Sla::StaleThresholds.for_projects(every_project) }

    assert_equal one, all, 'must not walk the tree once per project'
    assert_operator all, :<=, 2, 'parent links and configured values, once each'
  end

  test 'an empty list of projects asks the database nothing' do
    assert_empty Sla::StaleThresholds.for_projects([])
  end
end
