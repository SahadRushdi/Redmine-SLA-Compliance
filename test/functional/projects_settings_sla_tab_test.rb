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
    assert_select '#sla-policy-form-container' do
      assert_select 'button#sla-override-load'
    end
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
end
