require_relative '../test_helper'

# Renders the real Project Settings page end-to-end: proves the tab partial, both form
# sections, the helper wiring into ProjectsController, and the per-permission section gating.
class ProjectsSettingsSlaTabTest < ActionController::TestCase
  tests ProjectsController

  fixtures :projects, :projects_trackers, :trackers, :issue_statuses, :workflows,
           :enumerations, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules

  setup do
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    @role = Role.find(1) # Manager — user 2 (jsmith)
    @role.add_permission!(:edit_sla_policy, :manage_sla_notifications)
    @request.session[:user_id] = 2
    SlaTargetOption.create!(target_type: 'response', code: '4h', label: '4 hours',
                            seconds: 14_400)
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  test "settings page renders both tab sections with saved values" do
    saved = SlaPolicy.create!(project_id: @project.id, enabled: true, at_risk_threshold: 85)
    status_id = @project.rolled_up_statuses.first.id
    saved.sla_status_mappings.create!(role: 'created', status_id: status_id)
    saved.sla_definitions.create!(tracker_id: @project.trackers.first.id,
                                  priority_id: IssuePriority.active.first.id,
                                  response_seconds: 14_400)
    SlaNotificationSetting.create!(project_id: @project.id,
                                   at_risk_email_recipients: ['ops@example.com'])

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#tab-content-sla_policy .sla-plugin' do
      assert_select '#sla-policy-form'
      assert_select '#sla-notification-form'
      assert_select 'input#sla_policy_at_risk_threshold[value="85"]'
      assert_select "select[name='status_mappings[created][]'] option[selected][value='#{status_id}']"
      assert_select '#sla-definitions-rows option[selected][value="14400"]'
      assert_select "option[selected][value='ops@example.com']"
    end
  end

  test "policy section is hidden for a notifications-only role" do
    @role.remove_permission!(:edit_sla_policy)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success
    assert_select '#sla-policy-form', 0
    assert_select '#sla-notification-form'
  end

  # --- Sectioned settings shell ----------------------------------------------------------------

  test "the sidebar lists every section and opens General by default" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    SlaPoliciesHelper::SECTIONS.each do |section|
      assert_select "a[data-sla-section-link='#{section[:key]}']", 1,
                    "the #{section[:key]} section must be reachable from the sidebar"
      assert_select "[data-sla-panel='#{section[:key]}']", 1
    end
    assert_select "a[data-sla-section-link='general'].is-active"
    assert_select "[data-sla-panel='general']:not(.hidden)"
    assert_select "[data-sla-panel='targets'].hidden"
  end

  test "the requested section is the one rendered open" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'exclusions' }
    assert_response :success

    assert_select "a[data-sla-section-link='exclusions'].is-active"
    assert_select "[data-sla-panel='exclusions']:not(.hidden)"
    assert_select "[data-sla-panel='general'].hidden"
  end

  test "an unknown section falls back to the first permitted one" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'nope' }
    assert_response :success
    assert_select "a[data-sla-section-link='general'].is-active"
  end

  # Regression: the clone/Override AJAX replaces #sla-policy-tab-body wholesale. The Notifications
  # form belongs to a different controller and its own save button, so it must sit OUTSIDE that
  # region — otherwise loading a clone source silently discards a webhook URL or recipient list
  # the user had typed but not yet saved.
  test "the notifications form is outside the region the clone AJAX replaces" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#sla-policy-tab-body #sla-notification-form', 0,
                  'a clone load would wipe unsaved notification input if the form were in here'
    assert_select '#sla-policy-tab-body' # the region itself still exists
    assert_select '#sla-notification-form'
  end

  test "a notifications-only role gets a sidebar of just that section, opened" do
    @role.remove_permission!(:edit_sla_policy)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select 'a[data-sla-section-link]', 1
    assert_select "a[data-sla-section-link='notifications'].is-active"
    assert_select "[data-sla-panel='notifications']:not(.hidden)"
  end

  test "the tab is absent without either permission" do
    @role.remove_permission!(:edit_sla_policy, :manage_sla_notifications)

    get :settings, params: { id: @project.identifier }
    assert_response :success
    assert_select '#tab-content-sla_policy', 0
  end

  # --- B3: inheritance banner, not a blank editable form ---------------------------------------
  #
  # The bug being regression-tested: a child project with no SLA policy of its own used to render
  # the SAME blank editable form as a project with no policy anywhere — and saving that blank
  # form silently created a disabled override, defeating inheritance. A child with an inherited
  # policy must never show `#sla-policy-form` at all.

  def grant_child_access(project)
    member = Member.find_or_initialize_by(user_id: 2, project_id: project.id)
    member.role_ids = (member.role_ids + [@role.id]).uniq
    member.save!
    project.enable_module!(:sla_compliance)
  end

  test "a project with no policy of its own but an inherited one shows the banner, not the form" do
    parent = Project.find(5) # private-child, parent = ecookbook (1)
    grant_child_access(parent)
    SlaPolicy.create!(project_id: @project.id, enabled: true) # ecookbook's own policy

    get :settings, params: { id: parent.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#sla-policy-form', 0, 'must never render the editable form for an inherited policy'
    assert_select '#sla-policy-tab-body' do
      assert_select 'button#sla-override-load'
    end
    # The four policy sections are not offered while the policy is inherited — there is nothing
    # editable behind them until Override is pressed.
    %w[general measurement targets exclusions].each do |key|
      assert_select "a[data-sla-section-link='#{key}']", 0
    end
    assert_select "a[data-sla-section-link='notifications']"
  end

  test "a project with its own policy renders the editable form even though its parent also has one" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true) # parent's policy
    SlaPolicy.create!(project_id: child.id, enabled: true)    # child's own policy wins

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#sla-policy-form'
    assert_select 'button#sla-override-load', 0
  end

  test "a project with no policy anywhere shows the blank form with a helper hint, not the banner" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#sla-policy-form'
    assert_select 'button#sla-override-load', 0
  end

  def revert_delete_form_selector(project)
    "form[action='#{project_sla_policy_path(project)}'] input[name='_method'][value='delete']"
  end

  test "Revert to inherited policy is offered only when an ancestor also has a policy" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true) # ancestor policy exists
    SlaPolicy.create!(project_id: child.id, enabled: true)    # and child has its own

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_select revert_delete_form_selector(child)
  end

  test "Revert to inherited policy is NOT offered when no ancestor has a policy" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: child.id, enabled: true) # only the child has one

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_select revert_delete_form_selector(child), 0
  end

  # --- Step 5.1: the user allow-list ------------------------------------------------------------
  #
  # "A non-permitted role sees neither the tab nor the dashboard; an admin can grant access to a
  # chosen role and it takes effect." These cover the TAB half for users granted individually
  # rather than through a role — the case Redmine's role-only permission model cannot express.
  #
  # All of them log in as rhill (user 4): active, but a member of no project and holding no role.
  # Anything they can see here was granted by the allow-list and by nothing else.

  def list!(list, *user_ids)
    Setting.plugin_redmine_sla_compliance = {
      "sla_#{list}_user_ids" => user_ids.map(&:to_s)
    }
  end

  test "a listed manager gets the tab and both sections with no role at all" do
    @request.session[:user_id] = 4
    list!(:manager, 4)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }

    assert_response :success, 'a listed manager must be able to open the Settings page itself'
    assert_select '#tab-content-sla_policy .sla-plugin' do
      assert_select '#sla-policy-form'
      assert_select '#sla-notification-form'
    end
  end

  test "a listed viewer is dashboard-only and never sees the tab" do
    @request.session[:user_id] = 4
    list!(:viewer, 4)

    get :settings, params: { id: @project.identifier }

    # The viewer list grants the dashboard only, so the page hosting the tab stays closed to them.
    assert_response :forbidden
  end

  test "an unlisted user with no role sees neither the tab nor the Settings page" do
    @request.session[:user_id] = 4

    get :settings, params: { id: @project.identifier }
    assert_response :forbidden
  end

  test "granting a manager takes effect immediately, with no restart" do
    @request.session[:user_id] = 4

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :forbidden, 'precondition: not listed yet'

    list!(:manager, 4)
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success
    assert_select '#sla-policy-form'

    Setting.plugin_redmine_sla_compliance = {}
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :forbidden, 'revoking must apply just as immediately'
  end

  test "a listed manager sees only the SLA tab, not the rest of Project Settings" do
    # Claiming projects/settings for :edit_sla_policy opens the page, but every other tab is
    # still filtered by its own permission — a listed manager must not gain project admin.
    @request.session[:user_id] = 4
    list!(:manager, 4)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }

    assert_response :success
    # The positive assertion pins the selector form, so the two negatives below cannot pass
    # vacuously by naming an id that never exists.
    assert_select 'a#tab-sla_policy'
    assert_select 'a#tab-info', 0, 'must not gain the project Information tab'
    assert_select 'a#tab-members', 0, 'must not gain the Members tab'
  end

  test "a role granted only edit_sla_policy can reach the tab without edit_project" do
    # The role-based counterpart of the above: before Step 5.1, :edit_sla_policy alone was not
    # enough to open ProjectsController#settings, so the tab was unreachable for such a role.
    role = Role.create!(name: 'SLA Only', permissions: [:view_project, :edit_sla_policy])
    Member.create!(user_id: 4, project_id: @project.id, role_ids: [role.id])
    @request.session[:user_id] = 4

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }

    assert_response :success
    assert_select '#sla-policy-form'
    assert_select '#sla-notification-form', 0, 'edit_sla_policy alone must not open notifications'
  end
end
