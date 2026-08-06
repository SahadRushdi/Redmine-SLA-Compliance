# frozen_string_literal: true

require_relative '../test_helper'

# Step 6.1 — SlaPolicy.enabled_projects_for: the "SLA-enabled projects the user can access"
# resolver behind both the dashboard's Project filter and the :application_menu :if condition.
# Uses the same fixture set / role-granting pattern as sla_dashboard_controller_test.rb.
class SlaPolicyTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses, :enumerations

  setup do
    @project = Project.find(1) # ecookbook
    @project.enable_module!(:sla_compliance)
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    @user = User.find(4) # rhill: active, no membership anywhere, no role
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  # Both halves of an SLA grant: a membership in a role that ticks no permission of its own, and
  # that role named in the plugin settings. See Sla::AccessControlTest for the two pulled apart.
  def grant_sla_access!(project = @project)
    @sla_role ||= Role.create!(name: 'SLA Access Test Role', permissions: [])
    Member.create!(principal: @user, project: project, roles: [@sla_role])
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => [@sla_role.id.to_s] }
  end

  test 'returns an active, visible, module-enabled, permitted project with an enabled policy' do
    grant_sla_access!

    assert_equal [@project], SlaPolicy.enabled_projects_for(@user)
  end

  test 'excludes a project whose module is disabled even when the user is granted' do
    @project.disable_module!(:sla_compliance)
    grant_sla_access!

    assert_equal [], SlaPolicy.enabled_projects_for(@user)
  end

  test 'excludes a project with a disabled SlaPolicy' do
    SlaPolicy.find_by(project_id: @project.id).update!(enabled: false)
    grant_sla_access!

    assert_equal [], SlaPolicy.enabled_projects_for(@user)
  end

  test 'excludes a project with no SlaPolicy at all' do
    SlaPolicy.find_by(project_id: @project.id).destroy!
    grant_sla_access!

    assert_equal [], SlaPolicy.enabled_projects_for(@user)
  end

  test 'excludes a project the user is not permitted to view even when it is SLA-enabled' do
    # No SLA access role, no role with view_sla_dashboard.
    assert_equal [], SlaPolicy.enabled_projects_for(@user)
  end

  test 'excludes a private project the user holds no role on, even when granted elsewhere' do
    private_project = Project.find(2) # OnlineStore — rhill is not a member
    private_project.enable_module!(:sla_compliance)
    SlaPolicy.create!(project_id: private_project.id, enabled: true)
    grant_sla_access!

    refute_includes SlaPolicy.enabled_projects_for(@user), private_project
  end

  test 'respects a narrower base_scope, never returning a project outside it' do
    # eCookbook Subproject 1 (id 3), made fully eligible in its own right — visible,
    # module-enabled, policy-enabled and granted — so this only passes if base_scope itself is
    # what excludes it, not visibility or permission.
    other_project = Project.find(3)
    other_project.enable_module!(:sla_compliance)
    SlaPolicy.create!(project_id: other_project.id, enabled: true)
    grant_sla_access!
    grant_sla_access!(other_project)

    result = SlaPolicy.enabled_projects_for(@user, base_scope: Project.where(id: @project.id))

    assert_equal [@project], result
  end

  test 'returns an empty array for an anonymous (not logged in) user without erroring' do
    assert_equal [], SlaPolicy.enabled_projects_for(User.anonymous)
  end

  test 'returns an empty array for a nil user' do
    assert_equal [], SlaPolicy.enabled_projects_for(nil)
  end
end
