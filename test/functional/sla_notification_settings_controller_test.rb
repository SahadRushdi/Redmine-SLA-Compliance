require_relative '../test_helper'

# Notification settings persistence + the permission split from the policy form.
class SlaNotificationSettingsControllerTest < ActionController::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules

  setup do
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    @role = Role.find(1) # Manager — user 2 (jsmith)
    @role.add_permission!(:manage_sla_notifications)
    @request.session[:user_id] = 2
  end

  def setting
    SlaNotificationSetting.find_by(project_id: @project.id)
  end

  test "update persists all fields including recipient arrays" do
    put :update, params: {
      project_id: @project.id,
      sla_notification_setting: {
        google_chat_webhook: 'https://chat.googleapis.com/v1/spaces/x/messages?key=y',
        at_risk_email_enabled: '1',
        at_risk_email_recipients: ['', 'ops@example.com', 'lead@example.com'],
        at_risk_email_frequency: 'digest',
        at_risk_digest_interval_minutes: '120',
        stale_email_enabled: '1',
        stale_email_recipients: ['', 'ops@example.com'],
        stale_email_frequency: 'monthly'
      }
    }
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy')
    saved = setting
    assert saved.at_risk_email_enabled?
    assert_equal %w[ops@example.com lead@example.com], saved.at_risk_email_recipients
    assert_equal 'digest', saved.at_risk_email_frequency
    assert_equal 120, saved.at_risk_digest_interval_minutes
    assert saved.stale_email_enabled?
    assert_equal %w[ops@example.com], saved.stale_email_recipients
    assert_equal 'monthly', saved.stale_email_frequency
    assert_includes saved.google_chat_webhook, 'chat.googleapis.com'
  end

  test "clearing every recipient persists an empty list" do
    SlaNotificationSetting.create!(project_id: @project.id,
                                   at_risk_email_recipients: ['ops@example.com'])
    put :update, params: {
      project_id: @project.id,
      sla_notification_setting: { at_risk_email_recipients: [''] }
    }
    assert_equal [], setting.at_risk_email_recipients
  end

  test "an invalid email is rejected with a flash error" do
    put :update, params: {
      project_id: @project.id,
      sla_notification_setting: { at_risk_email_recipients: ['not-an-email'] }
    }
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy')
    assert flash[:error].present?
    assert_nil setting
  end

  test "edit_sla_policy alone does not grant notification management" do
    @role.remove_permission!(:manage_sla_notifications)
    @role.add_permission!(:edit_sla_policy)
    put :update, params: { project_id: @project.id,
                           sla_notification_setting: { stale_email_frequency: 'daily' } }
    assert_response :forbidden
    assert_nil setting
  end

  test "update is forbidden when the module is disabled" do
    @project.disable_module!(:sla_compliance)
    put :update, params: { project_id: @project.id,
                           sla_notification_setting: { stale_email_frequency: 'daily' } }
    assert_response :forbidden
  end
end
