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
    # A role with NO permissions of its own, so nothing it grants can be mistaken for the
    # plugin's doing — the point of the feature is that the role need not know about SLA.
    @role = Role.create!(name: 'SLA Access Test Role', permissions: [])
    # rhill: active, no membership anywhere, no role. Anything they can do came from the grant.
    @user = User.find(4)
    @request.session[:user_id] = @user.id
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  # Both halves of an SLA grant: hold a role on the project, and have that role named in the
  # plugin settings. Neither is sufficient alone — see Sla::AccessControlTest, which pulls the two
  # apart; here they always travel together because every test below is about what a granted user
  # then sees.
  def grant_sla_access!(user = @user, project = @project, role = @role)
    Member.create!(principal: user, project: project, roles: [role])
    ids = Sla::PluginSettings.access_role_ids.map(&:to_s) | [role.id.to_s]
    Setting.plugin_redmine_sla_compliance =
      Setting.plugin_redmine_sla_compliance.merge('sla_access_role_ids' => ids)
  end

  # --- denied ---------------------------------------------------------------------------------

  test "a user with no role and no grant cannot open the dashboard" do
    get :index, params: { project_id: @project.id }
    assert_response :forbidden
  end

  test "a role that is neither permitted nor granted cannot open the dashboard" do
    @request.session[:user_id] = 2 # jsmith, Manager on project 1, but no SLA permission
    get :index, params: { project_id: @project.id }
    assert_response :forbidden
  end

  test "holding a role that is not in the SLA list cannot open the dashboard" do
    Member.create!(principal: @user, project: @project, roles: [@role])

    get :index, params: { project_id: @project.id }

    assert_response :forbidden, 'the role must be named in the settings before it grants anything'
  end

  # --- granted --------------------------------------------------------------------------------

  test "a member holding an SLA access role opens the dashboard" do
    grant_sla_access!

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select '.sla-plugin'
  end

  test "the dashboard does not load a browser auto-refresh script" do
    grant_sla_access!

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select 'script[src*="sla_dashboard_live"]', 0
  end

  # Redmine picks the highlighted menu entry by comparing each item's name to the controller's
  # current_menu_item, which defaults to the CONTROLLER name (:sla_dashboard) — not the name the
  # menu entry is registered under (:sla_compliance). Without the explicit `menu_item` declarations
  # in SlaDashboardController the tab never highlighted while you were standing on the dashboard.
  test "the project's SLA Compliance tab is marked selected while the dashboard is open" do
    grant_sla_access!

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select '#main-menu a.sla-compliance.selected'
  end

  test "project dashboard title uses a hyphen before the project name" do
    grant_sla_access!

    get :index, params: { project_id: @project.identifier }

    assert_response :success
    assert_select 'h1', text: "SLA Compliance - #{@project.name}"
    assert_select 'title', text: /SLA Compliance - #{@project.name}/
  end

  test "the cross-project dashboard selects the top-level SLA entry, not the project tab" do
    grant_sla_access!
    SlaPolicy.create!(project_id: @project.id, enabled: true)

    get :cross_project

    assert_response :success
    assert_select '#main-menu a.sla-dashboard-all.selected'
  end

  test "a role that ticks the permission itself still opens the dashboard" do
    # The other route in, unchanged by the SLA role list: an ordinary Redmine role with
    # :view_sla_dashboard ticked on its own permission form.
    Role.find(1).add_permission!(:view_sla_dashboard) # Manager — jsmith (user 2) holds it
    @request.session[:user_id] = 2

    get :index, params: { project_id: @project.id }
    assert_response :success
  end

  # --- the "takes effect" half of the Done when -----------------------------------------------

  test "granting and revoking a role takes effect immediately, with no restart" do
    get :index, params: { project_id: @project.id }
    assert_response :forbidden, 'precondition: nothing granted yet'

    grant_sla_access!
    get :index, params: { project_id: @project.id }
    assert_response :success, 'a saved grant must apply on the very next request'

    Setting.plugin_redmine_sla_compliance = {}
    get :index, params: { project_id: @project.id }
    assert_response :forbidden, 'revoking must apply just as immediately'
  end

  test "naming one role grants every member who holds it" do
    # The point of moving from a user list to a role list: adding a person to the role is the
    # whole of the administration, with no second list to keep in step.
    grant_sla_access!
    grant_sla_access!(User.find(7))

    get :index, params: { project_id: @project.id }
    assert_response :success

    @request.session[:user_id] = 7
    get :index, params: { project_id: @project.id }
    assert_response :success
  end

  # --- the guarantees -------------------------------------------------------------------------

  test "a granted member is still refused when the module is disabled" do
    @project.disable_module!(:sla_compliance)
    grant_sla_access!

    get :index, params: { project_id: @project.id }
    assert_response :forbidden
  end

  test "a granted role does not carry to a project the user holds no role on" do
    # The no-leak guarantee: the grant follows the membership, not the person. OnlineStore is
    # private and rhill is not a member, so the role they hold on eCookbook buys nothing here.
    private_project = Project.find(2)
    private_project.enable_module!(:sla_compliance)
    grant_sla_access!

    get :index, params: { project_id: private_project.id }

    assert_response :forbidden
  end

  # --- Step 6.1: the top-level (cross-project) route -------------------------------------------

  test "the top-level dashboard 403s for a user with no permitted project anywhere" do
    # @project (1) has the module enabled but no SlaPolicy row in this setup, so it isn't
    # SLA-enabled even though the module is on — SlaPolicy.enabled_projects_for requires both.
    grant_sla_access!

    get :cross_project

    assert_response :forbidden
  end

  test "the top-level dashboard succeeds for a granted member with a permitted project, listing it" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!

    get :cross_project

    assert_response :success
    assert_select '.sla-plugin'
    assert_select "#sla-filter-projects option[value='#{@project.id}']"
  end

  # --- Step 6.1: project-level Project filter is scoped to the subtree, not the full universe --

  test "the project-level Project filter includes an SLA-enabled descendant but excludes a non-descendant" do
    descendant = Project.find(3) # eCookbook Subproject 1, parent_id: 1, public
    # OnlineStore (2) has no parent -- not a descendant of @project (1). Give the user a real
    # membership on it, in the SLA access role, so it's otherwise fully eligible (visible,
    # module-enabled, policy-enabled, granted) -- the only thing that should exclude it here is
    # base_scope, not visibility.
    unrelated = Project.find(2)
    Member.create!(project: unrelated, principal: @user, role_ids: [@role.id])
    [@project, descendant, unrelated].each do |p|
      p.enable_module!(:sla_compliance)
      SlaPolicy.create!(project_id: p.id, enabled: true)
    end
    # The grant follows the membership, so each project the filter may offer needs one.
    grant_sla_access!
    grant_sla_access!(@user, descendant)

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select "#sla-filter-projects option[value='#{descendant.id}']"
    assert_select "#sla-filter-projects option[value='#{unrelated.id}']", 0
  end

  test "a project with no descendants renders the Project filter locked" do
    leaf = Project.find(4) # eCookbook Subproject 2 -- public, no children in the fixture set
    leaf.enable_module!(:sla_compliance)
    SlaPolicy.create!(project_id: leaf.id, enabled: true)
    grant_sla_access!(@user, leaf)

    get :index, params: { project_id: leaf.id }

    assert_response :success
    assert_select '#sla-filter-projects[disabled]'
  end

  # --- Step 6.1: filter params are clamped, never trusted verbatim -----------------------------

  test "a project_id outside the permitted set is silently dropped, not a 403" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!

    get :index, params: { project_id: @project.id, project_ids: [Project.find(2).id] }

    assert_response :success
    # Clamped back to the only permitted project (@project), not the tampered id.
    assert_select "#sla-filter-projects option[selected][value='#{@project.id}']"
    assert_select "#sla-filter-projects option[selected][value='2']", 0
  end

  test "a tracker_id not configured for the selected project is dropped" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!

    get :index, params: { project_id: @project.id, tracker_ids: [999] }

    assert_response :success
    # 999 isn't a configured tracker (no SlaDefinition exists for it), so it shouldn't even be
    # rendered as a selectable option, let alone the selected one.
    assert_select "#sla-filter-tracker option[value='999']", 0
  end

  test "a malformed custom date range falls back to no date filter without a 500" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!

    get :index, params: { project_id: @project.id, date_preset: 'custom', from: 'not-a-date', to: 'also-not-a-date' }

    assert_response :success
  end

  test "an unrecognized date_preset falls back to this_week, not passed through verbatim" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!

    get :index, params: { project_id: @project.id, date_preset: 'not-a-real-preset' }

    assert_response :success
    assert_select "#sla-filter-date-preset option[selected][value='this_week']"
    assert_select "#sla-filter-date-preset option[value='not-a-real-preset']", 0
  end

  # --- Step 6.2: summary cards reconcile in the rendered response ------------------------------

  test "summary cards count evaluated tickets only and do not render a No SLA card" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!

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
    assert_select '#sla-card-total-value', text: '2'
    # SLA Met is no longer a summary card (it moved to the SLA Trend tab); the current-state row now
    # carries Stale in its place. No inactivity threshold is configured in this test, and there is no
    # built-in one, so the card reports "not configured" rather than a count (see the Stale tests
    # below).
    assert_select '#sla-card-stale-value', text: '—'
    assert_select '#sla-card-breached-value', text: '1'
    assert_select '#sla-card-breached-percentage', 0
    assert_select '#sla-card-no-sla-value', 0
    assert_select '#sla-card-not-tracked-value', 0
    assert_select '#sla-card-not-configured-value', 0
    assert_select '.lg\\:tw-grid-cols-4', 1
  end

  # --- the Stale card: admin-configured, and honest when it isn't ----------------------------

  def seed_idle_ticket(idle_days, stale_threshold_days: nil)
    SlaPolicy.create!(project_id: @project.id, enabled: true,
                      stale_threshold_days: stale_threshold_days)
    grant_sla_access!
    issue = Issue.generate!(project: @project, tracker_id: @project.trackers.first.id, priority_id: 4)
    issue.update_columns(updated_on: idle_days.days.ago)
    SlaResult.find_by!(issue_id: issue.id)
             .update!(primary_state: 'met', no_sla_reason: nil, resolved_at: nil)
    issue
  end

  test "with no threshold configured the Stale card shows a dash and tells you where to set one" do
    seed_idle_ticket(400) # idle over a year: still not "stale", because nobody has defined stale

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select '#sla-card-stale-value', text: '—', count: 1
    assert_select '#sla-card-stale-hint', text: I18n.t(:label_sla_card_stale_unset_caption)
  end

  test "the project's own threshold counts its idle open tickets" do
    seed_idle_ticket(3, stale_threshold_days: 2)

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select '#sla-card-stale-value', text: '1'
    assert_select '#sla-card-stale-hint', text: I18n.t(:label_sla_card_stale_caption)
  end

  test "a ticket idle for less than the project's threshold is not stale" do
    seed_idle_ticket(1, stale_threshold_days: 2)

    get :index, params: { project_id: @project.id }

    assert_select '#sla-card-stale-value', text: '0', count: 1
  end

  # --- Open-ticket semantics and period-scoped SLA Trend --------------------------------------

  test "a resolved ticket is excluded from every open-ticket card" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset
    # Resolved per the engine's own resolved-role milestone, which is what sla_results records —
    # NOT issues.closed_on.
    SlaResult.find_by!(issue_id: issues[:breached].id).update!(resolved_at: 2.days.ago)

    get :index, params: { project_id: @project.id }

    # Three evaluated tickets remain open, and of the two breached rows only the live-breached one
    # is left. The No-SLA fixture is outside the dashboard population throughout.
    assert_select '#sla-card-total-value', text: '3'
    assert_select '#sla-card-breached-value', text: '1'
    assert_select "#sla-detail-row-#{issues[:breached].id}", 0
    assert_equal 3, parse_chart_data('sla-donut-chart')['total']
  end

  test "the date range moves Trend SLA Met but does not move any open-ticket card" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset
    SlaResult.find_by!(issue_id: issues[:met].id)
             .update!(resolved_at: Time.zone.local(2026, 7, 15, 9, 0, 0))
    SlaResult.find_by!(issue_id: issues[:breached].id)
             .update!(resolved_at: Time.zone.local(2026, 7, 16, 9, 0, 0))

    [['07/01/2026', '07/31/2026', '1', '2'],
     ['08/01/2026', '08/31/2026', '0', '0']].each do |from, to, met, total|
      get :index, params: { project_id: @project.id, date_preset: 'custom', from: from, to: to }

      assert_select '#sla-card-total-value', text: '2'
      assert_select '#sla-card-breached-value', text: '1'
      assert_select '#sla-card-at-risk-value', text: '1'
      assert_select '#sla-card-no-sla-value', 0
      assert_select '#sla-met-window-value', text: met
      noun = total == '1' ? 'ticket' : 'tickets'
      assert_select '#sla-met-window-caption',
                    text: "#{met} of #{total} resolved #{noun} met their SLA target"
    end
  end

  test "the SLA Met card uses only tickets resolved in the selected period" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset
    issues.each_value do |issue|
      SlaResult.find_by!(issue_id: issue.id)
               .update!(cycle_started_at: Time.zone.local(2026, 7, 1, 9, 0, 0))
    end
    SlaResult.find_by!(issue_id: issues[:met].id)
             .update!(resolved_at: Time.zone.local(2026, 7, 2, 9, 0, 0))
    SlaResult.find_by!(issue_id: issues[:breached].id)
             .update!(resolved_at: Time.zone.local(2026, 6, 30, 9, 0, 0))

    get :index, params: { project_id: @project.id, date_preset: 'custom',
                          from: '07/01/2026', to: '07/31/2026' }

    assert_select '#sla-met-window-percentage', text: '100.0'
    assert_select '#sla-met-window-value', text: '1'
    assert_select '#sla-met-window-caption', text: '1 of 1 resolved ticket met their SLA target'
    assert_equal 2, parse_chart_data('sla-donut-chart')['total'],
                 'both resolved tickets are correctly absent from the current-open donut'
    assert_equal 4, parse_chart_data('sla-trend-chart')['datasets'].first['data'].sum,
                 'Created remains independently based on cycle_started_at'
  end

  test "the SLA Met card shows zero percent and a zero count when no tickets resolved in the period" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!

    get :index, params: { project_id: @project.id, date_preset: 'custom',
                          from: '07/01/2026', to: '07/31/2026' }

    assert_select '#sla-met-window-percentage', text: '0'
    assert_select '#sla-met-window-value', text: '0'
    assert_select '#sla-met-window-caption', text: '0 of 0 resolved tickets met their SLA target'
  end

  test "the Created vs Resolved chart maps each timestamp to the correct series and day" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset
    issues.each_value do |issue|
      SlaResult.find_by!(issue_id: issue.id)
               .update!(cycle_started_at: Time.zone.local(2026, 6, 1, 9, 0, 0))
    end
    SlaResult.find_by!(issue_id: issues[:met].id)
             .update!(cycle_started_at: Time.zone.local(2026, 7, 1, 9, 0, 0))
    SlaResult.find_by!(issue_id: issues[:at_risk].id)
             .update!(cycle_started_at: Time.zone.local(2026, 7, 2, 9, 0, 0))
    SlaResult.find_by!(issue_id: issues[:met].id)
             .update!(resolved_at: Time.zone.local(2026, 7, 2, 15, 0, 0))

    get :index, params: { project_id: @project.id, date_preset: 'custom',
                          from: '07/01/2026', to: '07/03/2026' }

    datasets = parse_chart_data('sla-trend-chart')['datasets']
    assert_equal [1, 1, 0], datasets[0]['data']
    assert_equal [0, 1, 0], datasets[1]['data']
  end

  # --- Step 6.3/6.4 helpers --------------------------------------------------------------------

  def parse_chart_data(id)
    JSON.parse(css_select("##{id}").first['data-chart'])
  end

  # met (on track), met + at_risk, a persisted breach, a stale-persisted-met-but-live-breached row
  # (breach_at already passed), and a no_sla row - verifies every dashboard surface agrees on
  # excluding the No-SLA ticket while retaining both evaluated states.
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
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select '#sla-donut-chart', 1
    assert_select '#sla-priority-chart', 1
    assert_select '#sla-trend-chart', 1
  end

  test "the donut sums evaluated tickets only, with at_risk as a subset and no No-SLA arc" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    donut = parse_chart_data('sla-donut-chart')
    assert_equal 3, donut['data'].size, 'met-on-track, met-at-risk and breached arc segments'
    assert_equal 3, donut['labels'].size
    assert_equal donut['total'], donut['data'].sum
    assert_equal 4, donut['total']
    refute_includes donut['labels'], I18n.t(:label_sla_card_no_sla)
  end

  test "the shared legend container renders exactly once" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select '#sla-chart-legend', 1
    assert_select '#sla-chart-legend .sla-legend-value', count: 3
    assert_select '#sla-chart-legend' do |legend|
      refute_includes legend.first.text, '%'
    end
  end

  test "the priority chart's embedded totals reconcile with the summary cards for the same scope" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    priority_chart = parse_chart_data('sla-priority-chart')
    total_across_priorities = priority_chart['datasets'].sum { |ds| ds['data'].sum }
    assert_equal 4, total_across_priorities
  end

  # --- Step 6.4: detail table ----------------------------------------------------------------

  test "detail table state tabs show the same counts as the summary cards" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select '#sla-detail-state-tabs' do
      assert_select 'button', text: /\AAll \(4\)\z/
      assert_select 'button', text: /\A#{Regexp.escape(I18n.t(:label_sla_card_met))} \(2\)\z/
      assert_select 'button', text: /\ASLA Breached \(2\)\z/
      assert_select 'button', text: /\AAt Risk \(1\)\z/
      assert_select "button[data-sla-state-filter='no_sla']", 0
    end
  end

  # The pills filter the already-rendered rows in place, like the search box, sorting and
  # pagination beside them — they were the last control on this table that still cost a page load
  # for data the browser already had.
  test "state tabs are client-side filter buttons, not server links" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id, date_preset: 'this_month' }

    assert_select '#sla-detail-state-tabs a', 0, 'a pill that is a link reloads the whole page'
    SlaDashboardController::DETAIL_STATES.each do |state|
      assert_select "#sla-detail-state-tabs button[data-sla-state-filter='#{state}']", 1
    end
  end

  # Every evaluated state's rows are on the page at once, because the pills filter what is already there.
  test "the detail table renders rows for every evaluated state so the pills can filter client-side" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id, state: 'breached' }

    assert_response :success
    assert_select '#sla-detail-table-body tr[data-sla-row]', 4,
                  'a state param must no longer shrink the rendered row set'
    assert_select "#sla-detail-row-#{issues[:met].id}", 1
    assert_select "#sla-detail-row-#{issues[:no_sla].id}", 0
    # The requested state still decides which pill opens active, so a bookmarked link still works.
    assert_select "button[data-sla-state-filter='breached'].is-active", minimum: 1
  end

  test "column headers are client-side sort triggers (typed, no server round-trip link)" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id, date_preset: 'this_month' }

    assert_response :success
    assert_select "th[data-sla-sort='ticket'][data-sla-sort-type='number']", 1
    assert_select "th[data-sla-sort='result'][data-sla-sort-type='number']", 1
    assert_select 'thead th a', 0 # sorting is client-side now — no per-header server links
  end

  test "the detail table renders every matching row for client-side pagination (no server pager)" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id, date_preset: 'this_month' }

    assert_response :success
    assert_select '#sla-detail-pagination', 1
    # All four evaluated rows are in the DOM for the client-side sorter/paginator to work over.
    assert_select '#sla-detail-table-body tr[data-sla-row]', 4
  end

  test "deviation column updates live for both persisted and live-reclassified breaches" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select "#sla-detail-row-#{issues[:breached].id} td:last-child", text: /1h/
    assert_select "#sla-detail-row-#{issues[:met].id} td:last-child", text: '—'
    assert_select "#sla-detail-row-#{issues[:live_breached].id} td:last-child", text: /1h/
  end

  test "the at-risk flag renders alongside the Met badge on an at-risk row, never replacing it" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select "#sla-detail-row-#{issues[:at_risk].id}" do
      assert_select 'span', text: I18n.t(:label_sla_card_met)
      assert_select 'span', text: 'At Risk'
    end
  end

  test "ticket and title links open in a new tab and point at Redmine's own issue_path" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select "#sla-detail-row-#{issues[:met].id} a[href='#{issue_path(issues[:met])}'][target='_blank'][rel='noopener']",
                  minimum: 1
  end

  # The client-side pills filter on each row's data-sla-state, so THAT attribute is where the
  # live-reclassification has to show up — a stale-met row whose breach_at has passed must carry
  # state "breached", or the Breached pill would disagree with the badge on the row and with the
  # summary cards. at_risk stays a flag on a met row, never a state of its own.
  test "each row carries its effective state for the pills, live-reclassifying a stale-met breach" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select "#sla-detail-row-#{issues[:breached].id}[data-sla-state='breached']"
    assert_select "#sla-detail-row-#{issues[:live_breached].id}[data-sla-state='breached']"
    assert_select "#sla-detail-row-#{issues[:met].id}[data-sla-state='met'][data-sla-at-risk='false']"
    assert_select "#sla-detail-row-#{issues[:at_risk].id}[data-sla-state='met'][data-sla-at-risk='true']"
    assert_select "#sla-detail-row-#{issues[:no_sla].id}", 0
  end

  # CSV has no client to do the filtering, so ?state= must still narrow the export server-side.
  test "CSV export still honours the state filter server-side" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id, state: 'breached', format: 'csv' }

    assert_response :success
    ticket_ids = CSV.parse(@response.body, headers: true).map { |r| r[I18n.t(:field_sla_detail_ticket)] }
    assert_includes ticket_ids, issues[:breached].id.to_s
    assert_includes ticket_ids, issues[:live_breached].id.to_s
    refute_includes ticket_ids, issues[:met].id.to_s
  end

  test "cards, donut total, priority-bar total, and detail table All count all agree for the same filtered scope" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id }

    assert_select '#sla-card-total-value', text: '4'
    donut = parse_chart_data('sla-donut-chart')
    assert_equal 4, donut['total']
    priority_chart = parse_chart_data('sla-priority-chart')
    assert_equal 4, priority_chart['datasets'].sum { |ds| ds['data'].sum }
    assert_select '#sla-detail-state-tabs button', text: /\AAll \(4\)\z/
  end

  # --- redesign pass: Export CSV, search, per-page ----------------------------------------------

  test "the Export CSV button links to the current page with format csv, ignoring detail-table state/search/sort" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    seed_reconciled_dataset

    get :index, params: { project_id: @project.id, date_preset: 'this_month', state: 'breached', q: 'whatever' }

    assert_select "a[href*='.csv'][href*='date_preset=this_month']" do |links|
      href = links.first['href']
      refute_includes href, 'state=breached'
      refute_includes href, 'q=whatever'
    end
  end

  test "format=csv returns a CSV listing every matching row, ignoring pagination" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id, format: 'csv' }

    assert_response :success
    assert_match %r{\Atext/csv}, @response.content_type
    rows = CSV.parse(@response.body, headers: true)
    assert_equal 4, rows.size
    ticket_ids = rows.map { |r| r[I18n.t(:field_sla_detail_ticket)] }
    assert_includes ticket_ids, issues[:breached].id.to_s
    refute_includes ticket_ids, issues[:no_sla].id.to_s
  end

  test "CSV export honors the active project/tracker/priority/date filters" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    other = Project.find(3)
    other.enable_module!(:sla_compliance)
    SlaPolicy.create!(project_id: other.id, enabled: true)
    # Granted on BOTH, so what keeps `other` out of the export below is the project filter under
    # test and not a missing permission.
    grant_sla_access!
    grant_sla_access!(@user, other)
    seed_reconciled_dataset
    other_issue = Issue.generate!(project: other, tracker_id: other.trackers.first.id, author_id: 2)
    SlaResult.find_by!(issue_id: other_issue.id).update!(primary_state: 'met', no_sla_reason: nil)

    get :cross_project, params: { project_ids: [@project.id], format: 'csv' }

    assert_response :success
    rows = CSV.parse(@response.body, headers: true)
    refute_includes rows.map { |r| r[I18n.t(:field_sla_detail_ticket)] }, other_issue.id.to_s
  end

  test "the detail table search box filters by ticket subject" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    tracker_id = @project.trackers.first.id
    matching = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2, subject: 'Unique Search Target')
    other = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2, subject: 'Something else entirely')
    SlaResult.find_by!(issue_id: matching.id).update!(primary_state: 'met', no_sla_reason: nil)
    SlaResult.find_by!(issue_id: other.id).update!(primary_state: 'met', no_sla_reason: nil)

    get :index, params: { project_id: @project.id, q: 'Search Target' }

    assert_response :success
    assert_select "#sla-detail-row-#{matching.id}"
    assert_select "#sla-detail-row-#{other.id}", 0
  end

  test "the detail table search box matches an exact ticket id" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    tracker_id = @project.trackers.first.id
    matching = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2)
    other = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2)
    SlaResult.find_by!(issue_id: matching.id).update!(primary_state: 'met', no_sla_reason: nil)
    SlaResult.find_by!(issue_id: other.id).update!(primary_state: 'met', no_sla_reason: nil)

    get :index, params: { project_id: @project.id, q: "##{matching.id}" }

    assert_response :success
    assert_select "#sla-detail-row-#{matching.id}"
    assert_select "#sla-detail-row-#{other.id}", 0
  end

  test "a search with no matches shows the empty state instead of every row" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    issues = seed_reconciled_dataset

    get :index, params: { project_id: @project.id, q: 'no-such-ticket-exists' }

    assert_response :success
    issues.each_value { |issue| assert_select "#sla-detail-row-#{issue.id}", 0 }
  end

  test "the per-page control offers the configured options; all rows render for client-side paging" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    grant_sla_access!
    tracker_id = @project.trackers.first.id
    4.times do
      issue = Issue.generate!(project: @project, tracker_id: tracker_id, author_id: 2)
      SlaResult.find_by!(issue_id: issue.id).update!(primary_state: 'met', no_sla_reason: nil)
    end

    with_settings per_page_options: '2, 25, 50' do
      get :index, params: { project_id: @project.id }
    end

    assert_response :success
    # Page size is a client-side concern now, so all 4 rows are rendered; the dropdown exposes the
    # admin's configured per-page options for the JS paginator to use.
    assert_select '#sla-detail-per-page[data-sla-perpage]', 1
    assert_select "#sla-detail-per-page option[value='2']", 1
    assert_select '#sla-detail-table-body tr[data-sla-row]', 4
  end

  # --- the menu entry: seeing the dashboard means being shown the way to it --------------------

  class SlaDashboardMenuTest < ActionController::TestCase
    tests ProjectsController

    fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
             :enabled_modules, :trackers, :projects_trackers, :issue_statuses, :enumerations

    setup do
      @project = Project.find(1)
      @project.enable_module!(:sla_compliance)
      @role = Role.create!(name: 'SLA Menu Test Role', permissions: [])
      @user = User.find(4) # rhill — no membership anywhere
      @request.session[:user_id] = @user.id
      Setting.plugin_redmine_sla_compliance = {}
    end

    teardown do
      Setting.plugin_redmine_sla_compliance = {}
    end

    # Same two halves as the outer class's helper; repeated rather than shared because this is a
    # separate TestCase against a different controller.
    def grant_sla_access!
      Member.create!(principal: @user, project: @project, roles: [@role])
      Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => [@role.id.to_s] }
    end

    test "the SLA menu entry is hidden from a user with no role and no grant" do
      get :show, params: { id: @project.identifier }
      assert_response :success
      assert_select '#main-menu a.sla-compliance', 0
    end

    test "a member holding an SLA access role is shown the SLA menu entry" do
      grant_sla_access!

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
      grant_sla_access!

      get :index

      assert_response :success
      assert_select '#main-menu a.sla-dashboard-all'
    end

    test "the top-level SLA menu entry is hidden for an anonymous user even with a permitted project" do
      SlaPolicy.create!(project_id: @project.id, enabled: true)
      grant_sla_access!
      @request.session[:user_id] = nil

      get :index

      assert_response :success
      assert_select '#main-menu a.sla-dashboard-all', 0
    end
  end
end
