require_relative '../test_helper'

# Step 4.1 "Done when": the SLA Policy tab appears in Project Settings for permitted roles
# only, and only while the module is enabled.
class SlaSettingsTabTest < ActionView::TestCase
  tests ProjectsHelper

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  setup do
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    @role = Role.find(1) # Manager — user 2 (jsmith) holds it on project 1
    @role.remove_permission!(:edit_sla_policy, :manage_sla_notifications)
    User.current = User.find(2)
  end

  teardown do
    User.current = nil
  end

  def sla_tab
    project_settings_tabs.detect { |tab| tab[:name] == 'sla_policy' }
  end

  test "tab appears for a role with edit_sla_policy" do
    @role.add_permission!(:edit_sla_policy)
    tab = sla_tab
    assert tab, 'tab should be present'
    assert_equal :edit_sla_policy, tab[:action]
    assert_equal 'projects/settings/sla_policy', tab[:partial]
  end

  test "tab appears for a role with only manage_sla_notifications" do
    @role.add_permission!(:manage_sla_notifications)
    tab = sla_tab
    assert tab, 'tab should be present'
    assert_equal :manage_sla_notifications, tab[:action]
  end

  test "tab is hidden without either permission" do
    assert_nil sla_tab
  end

  test "tab is hidden when the module is disabled, even with permission" do
    @role.add_permission!(:edit_sla_policy)
    @project.disable_module!(:sla_compliance)
    @project.reload
    assert_nil sla_tab
  end

  test "tab appears for an admin" do
    User.current = User.find(1)
    assert sla_tab
  end
end
