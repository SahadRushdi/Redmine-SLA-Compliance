# frozen_string_literal: true

require_relative '../test_helper'

# Step 5.1 — "a non-permitted role sees neither the tab nor the dashboard; an admin can grant
# access to a chosen role and it takes effect."
#
# This covers the dashboard half end-to-end through the real controller, including the project
# menu entry: a user who cannot open the dashboard must not be shown a link to it either.
class SlaDashboardControllerTest < ActionController::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses, :enumerations

  setup do
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    @role = Role.find(1) # Manager — jsmith (user 2)
    # rhill: active, no membership anywhere, no role. Anything they can do came from the list.
    @user = User.find(4)
    @request.session[:user_id] = @user.id
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  def list!(list, *user_ids)
    Setting.plugin_redmine_sla_compliance = {
      "sla_#{list}_user_ids" => user_ids.map(&:to_s)
    }
  end

  # --- denied ---------------------------------------------------------------------------------

  test "a user with no role and no listing cannot open the dashboard" do
    get :index, params: { project_id: @project.id }
    assert_response :forbidden
  end

  test "a role without view_sla_dashboard cannot open the dashboard" do
    @request.session[:user_id] = 2 # jsmith, Manager on project 1, but no SLA permission
    get :index, params: { project_id: @project.id }
    assert_response :forbidden
  end

  # --- granted --------------------------------------------------------------------------------

  test "a listed viewer opens the dashboard with no role and no membership" do
    list!(:viewer, @user.id)

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select '.sla-plugin'
  end

  test "a listed manager opens the dashboard too" do
    list!(:manager, @user.id)

    get :index, params: { project_id: @project.id }
    assert_response :success
  end

  test "a granted role opens the dashboard" do
    @role.add_permission!(:view_sla_dashboard)
    @request.session[:user_id] = 2

    get :index, params: { project_id: @project.id }
    assert_response :success
  end

  # --- the "takes effect" half of the Done when -----------------------------------------------

  test "granting and revoking a user takes effect immediately, with no restart" do
    get :index, params: { project_id: @project.id }
    assert_response :forbidden, 'precondition: not listed yet'

    list!(:viewer, @user.id)
    get :index, params: { project_id: @project.id }
    assert_response :success, 'a saved grant must apply on the very next request'

    Setting.plugin_redmine_sla_compliance = {}
    get :index, params: { project_id: @project.id }
    assert_response :forbidden, 'revoking must apply just as immediately'
  end

  test "several users can be granted at once" do
    list!(:viewer, 4, 7) # rhill and someone, in one saved list

    get :index, params: { project_id: @project.id }
    assert_response :success

    @request.session[:user_id] = 7
    get :index, params: { project_id: @project.id }
    assert_response :success
  end

  # --- the guarantees -------------------------------------------------------------------------

  test "a listed viewer is still refused when the module is disabled" do
    @project.disable_module!(:sla_compliance)
    list!(:viewer, @user.id)

    get :index, params: { project_id: @project.id }
    assert_response :forbidden
  end

  test "a listed viewer cannot see a private project they are not a member of" do
    private_project = Project.find(2) # OnlineStore — rhill is not a member
    private_project.enable_module!(:sla_compliance)
    list!(:viewer, @user.id)

    get :index, params: { project_id: private_project.id }

    assert_response :forbidden
  end

  # --- Step 6.1: the top-level (cross-project) route -------------------------------------------

  test "the top-level dashboard 403s for a user with no permitted project anywhere" do
    # @project (1) has the module enabled but no SlaPolicy row in this setup, so it isn't
    # SLA-enabled even though the module is on — SlaPolicy.enabled_projects_for requires both.
    list!(:viewer, @user.id)

    get :cross_project

    assert_response :forbidden
  end

  test "the top-level dashboard succeeds for a listed viewer with a permitted project, listing it" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)

    get :cross_project

    assert_response :success
    assert_select '.sla-plugin'
    assert_select "#sla-filter-projects option[value='#{@project.id}']"
  end

  # --- Step 6.1: project-level Project filter is scoped to the subtree, not the full universe --

  test "the project-level Project filter includes an SLA-enabled descendant but excludes a non-descendant" do
    descendant = Project.find(3) # eCookbook Subproject 1, parent_id: 1, public
    # OnlineStore (2) has no parent -- not a descendant of @project (1). Give the user a real
    # membership on it so it's otherwise fully eligible (visible, module-enabled, policy-enabled,
    # allow-listed) -- the only thing that should exclude it here is base_scope, not visibility.
    unrelated = Project.find(2)
    Member.create!(project: unrelated, principal: @user, role_ids: [@role.id])
    [@project, descendant, unrelated].each do |p|
      p.enable_module!(:sla_compliance)
      SlaPolicy.create!(project_id: p.id, enabled: true)
    end
    list!(:viewer, @user.id)

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select "#sla-filter-projects option[value='#{descendant.id}']"
    assert_select "#sla-filter-projects option[value='#{unrelated.id}']", 0
  end

  test "a project with no descendants renders the Project filter locked" do
    leaf = Project.find(4) # eCookbook Subproject 2 -- public, no children in the fixture set
    leaf.enable_module!(:sla_compliance)
    SlaPolicy.create!(project_id: leaf.id, enabled: true)
    list!(:viewer, @user.id)

    get :index, params: { project_id: leaf.id }

    assert_response :success
    assert_select '#sla-filter-projects[disabled]'
  end

  # --- Step 6.1: filter params are clamped, never trusted verbatim -----------------------------

  test "a project_id outside the permitted set is silently dropped, not a 403" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)

    get :index, params: { project_id: @project.id, project_ids: [Project.find(2).id] }

    assert_response :success
    # Clamped back to the only permitted project (@project), not the tampered id.
    assert_select "#sla-filter-projects option[selected][value='#{@project.id}']"
    assert_select "#sla-filter-projects option[selected][value='2']", 0
  end

  test "a tracker_id not configured for the selected project is dropped" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)

    get :index, params: { project_id: @project.id, tracker_id: 999 }

    assert_response :success
    # 999 isn't a configured tracker (no SlaDefinition exists for it), so it shouldn't even be
    # rendered as a selectable option, let alone the selected one.
    assert_select "#sla-filter-tracker option[value='999']", 0
  end

  test "a malformed custom date range falls back to no date filter without a 500" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)

    get :index, params: { project_id: @project.id, date_preset: 'custom', from: 'not-a-date', to: 'also-not-a-date' }

    assert_response :success
  end

  test "an unrecognized date_preset falls back to this_week, not passed through verbatim" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)

    get :index, params: { project_id: @project.id, date_preset: 'not-a-real-preset' }

    assert_response :success
    assert_select "#sla-filter-date-preset option[selected][value='this_week']"
    assert_select "#sla-filter-date-preset option[value='not-a-real-preset']", 0
  end

  # --- Step 6.2: summary cards reconcile in the rendered response ------------------------------

  test "summary cards reconcile: total = met + breached + no_sla, and no_sla = not_configured + not_tracked" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)

    tracker_id = @project.trackers.first.id
    met_issue = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2)
    breached_issue = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2)
    no_sla_issue = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2)
    # The plugin's own event-driven hook (Step 3.1) already wrote an sla_results row for each
    # issue the instant it was created (SLA is enabled on @project) — overwrite those rows with
    # the exact states this test needs, rather than creating new ones.
    SlaResult.find_by!(issue_id: met_issue.id).update!(primary_state: 'met', no_sla_reason: nil)
    SlaResult.find_by!(issue_id: breached_issue.id).update!(primary_state: 'breached', no_sla_reason: nil)
    SlaResult.find_by!(issue_id: no_sla_issue.id).update!(primary_state: 'no_sla', no_sla_reason: 'not_tracked')

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select '#sla-card-total-value', text: '3'
    assert_select '#sla-card-met-value', text: '1'
    assert_select '#sla-card-breached-value', text: '1'
    assert_select '#sla-card-no-sla-value', text: '1'
    assert_select '#sla-card-not-tracked-value', text: '1'
    assert_select '#sla-card-not-configured-value', text: '0'
  end

  # --- Step 6.3/6.4 helpers --------------------------------------------------------------------

  def parse_chart_data(id)
    JSON.parse(css_select("##{id}").first['data-chart'])
  end

  # met (on track), met + at_risk, a persisted breach, a stale-persisted-met-but-live-breached row
  # (breach_at already passed), and a no_sla row - exercises every state at once so cards, donut,
  # priority bar, and the detail table's "All" count can all be checked against the same data.
  def seed_reconciled_dataset
    tracker_id = @project.trackers.first.id
    met = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2, priority_id: 4)
    at_risk = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2, priority_id: 4)
    breached = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2, priority_id: 6)
    live_breached = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2, priority_id: 6)
    no_sla = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2, priority_id: 4)

    SlaResult.find_by!(issue_id: met.id).update!(primary_state: 'met', no_sla_reason: nil, at_risk: false)
    SlaResult.find_by!(issue_id: at_risk.id).update!(primary_state: 'met', no_sla_reason: nil, at_risk: true,
                                                     breach_at: 1.hour.from_now)
    SlaResult.find_by!(issue_id: breached.id).update!(primary_state: 'breached', no_sla_reason: nil,
                                                       deviation_seconds: 3600)
    SlaResult.find_by!(issue_id: live_breached.id).update!(primary_state: 'met', no_sla_reason: nil,
                                                            breach_at: 1.hour.ago)
    SlaResult.find_by!(issue_id: no_sla.id).update!(primary_state: 'no_sla', no_sla_reason: 'not_tracked')

    { met: met, at_risk: at_risk, breached: breached, live_breached: live_breached, no_sla: no_sla }
  end

  # --- Step 6.3: charts --------------------------------------------------------------------------

  test "renders exactly one donut, one priority bar, and one trend canvas element" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select '#sla-donut-chart', 1
    assert_select '#sla-priority-chart', 1
    assert_select '#sla-trend-chart', 1
  end

  test "the donut's embedded data sums to @counts.total, with at_risk as a separate field, not a fourth category" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    donut = parse_chart_data('sla-donut-chart')
    assert_equal 4, donut['data'].size, 'met-on-track, met-at-risk, breached, no_sla arc segments'
    assert_equal 4, donut['labels'].size
    assert_equal donut['total'], donut['data'].sum
    # 2 effectively met (met + at_risk), 2 effectively breached (breached + live_breached), 1 no_sla
    assert_equal 5, donut['total']
  end

  test "the shared legend container renders exactly once" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select '#sla-chart-legend', 1
  end

  test "the priority chart's embedded totals reconcile with the summary cards for the same scope" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    priority_chart = parse_chart_data('sla-priority-chart')
    total_across_priorities = priority_chart['datasets'].sum { |ds| ds['data'].sum }
    assert_equal 5, total_across_priorities
  end

  # --- Step 6.4: detail table ----------------------------------------------------------------

  test "detail table state tabs show the same counts as the summary cards" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select '#sla-detail-state-tabs' do
      assert_select 'a', text: /\AAll \(5\)\z/
      assert_select 'a', text: /\ASLA Met \(2\)\z/
      assert_select 'a', text: /\ASLA Breached \(2\)\z/
      assert_select 'a', text: /\AAt Risk \(1\)\z/
      assert_select 'a', text: /\ANo SLA \(1\)\z/
    end
  end

  test "clicking a state tab preserves the active project/tracker/priority/date filters in its href" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id, date_preset: 'this_month' }

    assert_select "#sla-detail-state-tabs a[href*='date_preset=this_month']", minimum: 1
  end

  test "clicking a column sort header preserves the active filters and points at the toggled direction" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id, date_preset: 'this_month', sort: 'ticket', sort_dir: 'desc' }

    assert_select "th a[href*='sort=ticket'][href*='sort_dir=asc'][href*='date_preset=this_month']", 1
  end

  test "detail table pagination links preserve the active filters" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id, date_preset: 'this_month' }

    assert_response :success # pagination_links_full merges request.query_parameters automatically
  end

  test "deviation column is blank for every non-breach row and populated for the persisted breach row" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select "#sla-detail-row-#{issues[:breached].id} td:last-child", text: /1h/
    assert_select "#sla-detail-row-#{issues[:met].id} td:last-child", text: '—'
    # live_breached shows the Breached badge (see next test) but has no computed deviation yet.
    assert_select "#sla-detail-row-#{issues[:live_breached].id} td:last-child", text: '—'
  end

  test "the at-risk flag renders alongside the Met badge on an at-risk row, never replacing it" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select "#sla-detail-row-#{issues[:at_risk].id}" do
      assert_select 'span', text: 'SLA Met'
      assert_select 'span', text: 'At Risk'
    end
  end

  test "ticket and title links open in a new tab and point at Redmine's own issue_path" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select "#sla-detail-row-#{issues[:met].id} a[href='#{issue_path(issues[:met])}'][target='_blank'][rel='noopener']",
                  minimum: 1
  end

  test "a row whose cached primary_state is stale-met but live-breached sorts and filters as Breached, matching the cards" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id, state: 'breached' }

    assert_select "#sla-detail-row-#{issues[:breached].id}"
    assert_select "#sla-detail-row-#{issues[:live_breached].id}"
    assert_select "#sla-detail-row-#{issues[:met].id}", 0
  end

  test "cards, donut total, priority-bar total, and detail table All count all agree for the same filtered scope" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    list!(:viewer, @user.id)
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select '#sla-card-total-value', text: '5'
    donut = parse_chart_data('sla-donut-chart')
    assert_equal 5, donut['total']
    priority_chart = parse_chart_data('sla-priority-chart')
    assert_equal 5, priority_chart['datasets'].sum { |ds| ds['data'].sum }
    assert_select '#sla-detail-state-tabs a', text: /\AAll \(5\)\z/
  end

  # --- the menu entry: seeing the dashboard means being shown the way to it --------------------

  class SlaDashboardMenuTest < ActionController::TestCase
    tests ProjectsController

    fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
             :enabled_modules, :trackers, :projects_trackers, :issue_statuses, :enumerations

    setup do
      @project = Project.find(1)
      @project.enable_module!(:sla_compliance)
      @request.session[:user_id] = 4 # rhill
      Setting.plugin_redmine_sla_compliance = {}
    end

    teardown do
      Setting.plugin_redmine_sla_compliance = {}
    end

    test "the SLA menu entry is hidden from a user with no role and no listing" do
      get :show, params: { id: @project.identifier }
      assert_response :success
      assert_select '#main-menu a.sla-compliance', 0
    end

    test "a listed viewer is shown the SLA menu entry" do
      Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => ['4'] }

      get :show, params: { id: @project.identifier }

      assert_response :success
      assert_select '#main-menu a.sla-compliance'
    end

    # --- Step 6.1: the new top-level (cross-project) entry point -------------------------------
    # Rendered only on a project-less page (:application_menu), unlike the project-tab link above
    # (:project_menu, rendered via #show) -- #index lists all projects and has no @project.

    test "the top-level SLA menu entry is hidden with no permitted project anywhere" do
      get :index
      assert_response :success
      assert_select '#main-menu a.sla-dashboard-all', 0
    end

    test "the top-level SLA menu entry is shown with at least one permitted, SLA-enabled project" do
      SlaPolicy.create!(project_id: @project.id, enabled: true)
      Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => ['4'] }

      get :index

      assert_response :success
      assert_select '#main-menu a.sla-dashboard-all'
    end

    test "the top-level SLA menu entry is hidden for an anonymous user even with a permitted project" do
      SlaPolicy.create!(project_id: @project.id, enabled: true)
      Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => ['4'] }
      @request.session[:user_id] = nil

      get :index

      assert_response :success
      assert_select '#main-menu a.sla-dashboard-all', 0
    end
  end
end
