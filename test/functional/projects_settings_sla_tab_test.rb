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
end
