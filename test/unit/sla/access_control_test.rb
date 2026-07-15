# frozen_string_literal: true

require_relative '../../test_helper'

# Step 5.1 — the user allow-list that fills the gap in Redmine's role-only permission model.
#
# Two layers are covered here, deliberately:
#   * Sla::AccessControl.granted? — the allow-list rule in isolation (service-object testing,
#     per the CLAUDE.md convention).
#   * User#allowed_to? — the real contract. Everything that gates SLA (before_action :authorize,
#     the project menu, the settings tab, the view partials) asks that method and never calls
#     AccessControl directly, so the patch being wired up is what actually matters.
class Sla::AccessControlTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules

  ALL_PERMISSIONS = %i[view_sla_dashboard edit_sla_policy manage_sla_notifications].freeze

  setup do
    @project = Project.find(1)  # eCookbook, public
    @project.enable_module!(:sla_compliance)
    # rhill: active, but a member of no project at all and holding no role — exactly the user the
    # allow-list exists for. Any access they get here came from the list, nothing else.
    @user = User.find(4)
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  def list!(list, *users)
    Setting.plugin_redmine_sla_compliance = {
      "sla_#{list}_user_ids" => users.map { |u| u.id.to_s }
    }
  end

  # --- the baseline: nobody is listed ---------------------------------------------------------

  test "a user with no role and no listing is denied everything" do
    ALL_PERMISSIONS.each do |permission|
      assert_not Sla::AccessControl.granted?(@user, permission, @project), permission.to_s
      assert_not @user.allowed_to?(permission, @project), permission.to_s
    end
  end

  # --- the viewer / manager split -------------------------------------------------------------

  test "a listed viewer gets the dashboard and nothing else" do
    list!(:viewer, @user)

    assert @user.allowed_to?(:view_sla_dashboard, @project)
    assert_not @user.allowed_to?(:edit_sla_policy, @project),
               'dashboard-only must not grant the policy form'
    assert_not @user.allowed_to?(:manage_sla_notifications, @project),
               'dashboard-only must not grant notification settings'
  end

  test "a listed manager gets all three permissions" do
    list!(:manager, @user)

    ALL_PERMISSIONS.each do |permission|
      assert @user.allowed_to?(permission, @project), permission.to_s
    end
  end

  test "a manager reaches the page that hosts the SLA Policy tab" do
    # ProjectsController#settings is gated on :edit_project (require_member), so without
    # :edit_sla_policy claiming projects/settings a listed manager would 403 on the page the tab
    # lives on and never see a Settings link — the tab could never be opened.
    list!(:manager, @user)

    assert @user.allowed_to?({ controller: 'projects', action: 'settings' }, @project)
  end

  test "a viewer does NOT reach the settings page" do
    list!(:viewer, @user)

    assert_not @user.allowed_to?({ controller: 'projects', action: 'settings' }, @project)
  end

  test "the controller/action form agrees with the permission form" do
    # Menu items with a Hash url are gated by allowed_to?(url), not by the permission name, so if
    # these two ever disagree a listed viewer is let into the dashboard but shown no link to it.
    list!(:viewer, @user)

    assert @user.allowed_to?({ controller: 'sla_dashboard', action: 'index' }, @project)
  end

  # --- the guarantees the allow-list must never break ------------------------------------------

  test "a listed user gets nothing on a project with the module disabled" do
    @project.disable_module!(:sla_compliance)
    # disable_module! destroys the EnabledModule row but leaves this instance's enabled_modules
    # association cache populated, so a stale object still reports the module as on. Every real
    # caller loads the project fresh per request; reload to match.
    @project.reload
    list!(:manager, @user)

    ALL_PERMISSIONS.each do |permission|
      assert_not @user.allowed_to?(permission, @project), permission.to_s
    end
  end

  test "a listed user gets nothing on a private project they cannot already see" do
    # The no-leak guarantee: the allow-list grants SLA permissions, never project visibility.
    private_project = Project.find(2) # OnlineStore — private, and rhill is not a member
    private_project.enable_module!(:sla_compliance)
    list!(:manager, @user)

    assert_not private_project.visible?(@user), 'fixture assumption: rhill cannot see project 2'
    ALL_PERMISSIONS.each do |permission|
      assert_not Sla::AccessControl.granted?(@user, permission, private_project), permission.to_s
      assert_not @user.allowed_to?(permission, private_project), permission.to_s
    end
  end

  test "anonymous is never granted, even if its id is listed somehow" do
    anonymous = User.anonymous
    Setting.plugin_redmine_sla_compliance = {
      'sla_manager_user_ids' => [anonymous.id.to_s]
    }

    ALL_PERMISSIONS.each do |permission|
      assert_not Sla::AccessControl.granted?(anonymous, permission, @project), permission.to_s
    end
  end

  test "an unrelated permission is never granted by the allow-list" do
    list!(:manager, @user)

    assert_not Sla::AccessControl.granted?(@user, :edit_project, @project)
    assert_not Sla::AccessControl.granted?(@user, :add_issues, @project)
  end

  test "granted? is false without a project" do
    list!(:manager, @user)

    assert_not Sla::AccessControl.granted?(@user, :view_sla_dashboard, nil)
  end

  # --- no regression for the role-based half (Step 0.2) ----------------------------------------

  test "a role grant still works for a user who is not listed" do
    role = Role.find(1) # Manager — jsmith (user 2) holds it on project 1
    role.add_permission!(:view_sla_dashboard)
    jsmith = User.find(2)

    assert jsmith.allowed_to?(:view_sla_dashboard, @project)
    assert_not Sla::AccessControl.granted?(jsmith, :view_sla_dashboard, @project),
               'the role, not the allow-list, is what granted this'
  end

  test "an admin still has access without being listed" do
    admin = User.find(1)

    ALL_PERMISSIONS.each do |permission|
      assert admin.allowed_to?(permission, @project), permission.to_s
    end
  end

  test "the allow-list never takes access away" do
    # It is purely additive: listing someone as a viewer must not downgrade a role that already
    # grants more than the viewer list does.
    role = Role.find(1)
    role.add_permission!(:edit_sla_policy)
    jsmith = User.find(2)
    list!(:viewer, jsmith)

    assert jsmith.allowed_to?(:edit_sla_policy, @project)
  end
end
