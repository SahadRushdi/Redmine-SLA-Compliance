# frozen_string_literal: true

require_relative '../../test_helper'

# Step 5.1 — the SLA access roles: "holding one of these roles is enough for the SLA permissions,
# whether or not the role itself ticks them".
#
# Two layers are covered here, deliberately:
#   * Sla::AccessControl.granted? — the rule in isolation (service-object testing, per the
#     CLAUDE.md convention).
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
    # rhill: active, but a member of no project at all. Any access they get here came from a
    # membership this test created plus the plugin's role list, nothing else.
    @user = User.find(4)
    # A role with NO permissions of its own, so nothing it grants can be mistaken for the
    # plugin's doing. This is the whole point of the feature: the role need not know about SLA.
    @role = Role.create!(name: 'SLA Access Test Role', permissions: [])
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  # The two halves of a grant, separately settable — several tests below turn on exactly one of
  # them to prove that neither is sufficient alone.
  def member!(user, role, project = @project)
    Member.create!(principal: user, project: project, roles: [role])
  end

  def configure_roles!(*roles)
    Setting.plugin_redmine_sla_compliance = {
      'sla_access_role_ids' => roles.map { |r| r.id.to_s }
    }
  end

  def grant!(user = @user, role = @role, project = @project)
    member!(user, role, project)
    configure_roles!(role)
  end

  # --- the baseline: nothing is configured -----------------------------------------------------

  test "a user with no role and no configured roles is denied everything" do
    ALL_PERMISSIONS.each do |permission|
      assert_not Sla::AccessControl.granted?(@user, permission, @project), permission.to_s
      assert_not @user.allowed_to?(permission, @project), permission.to_s
    end
  end

  # --- both halves are required ----------------------------------------------------------------

  test "a member of a configured role gets all three permissions" do
    grant!

    ALL_PERMISSIONS.each do |permission|
      assert @user.allowed_to?(permission, @project), permission.to_s
    end
  end

  test "holding the role grants nothing while that role is not configured" do
    member!(@user, @role)

    ALL_PERMISSIONS.each do |permission|
      assert_not @user.allowed_to?(permission, @project), permission.to_s
    end
  end

  test "configuring a role grants nothing to someone who does not hold it" do
    configure_roles!(@role)

    ALL_PERMISSIONS.each do |permission|
      assert_not @user.allowed_to?(permission, @project), permission.to_s
    end
  end

  test "holding a DIFFERENT role from the configured one grants nothing" do
    other_role = Role.create!(name: 'SLA Unlisted Test Role', permissions: [])
    member!(@user, other_role)
    configure_roles!(@role)

    assert_not @user.allowed_to?(:view_sla_dashboard, @project)
  end

  test "any one of several configured roles is enough" do
    other_role = Role.create!(name: 'SLA Second Test Role', permissions: [])
    member!(@user, other_role)
    configure_roles!(@role, other_role)

    assert @user.allowed_to?(:view_sla_dashboard, @project)
  end

  test "the grant is per-project: a role held on one project does not carry to another" do
    # grant! makes rhill a member of project 1 only, so project 3 is a public project they can
    # SEE but hold no role on — exactly the case that must not leak.
    elsewhere = Project.find(3)
    elsewhere.enable_module!(:sla_compliance)
    grant!

    assert elsewhere.visible?(@user), 'fixture assumption: project 3 is visible to rhill'
    assert_empty @user.roles_for_project(elsewhere).select { |r| r.id == @role.id },
                 'fixture assumption: the membership must not be inherited by the subproject'
    assert_not @user.allowed_to?(:view_sla_dashboard, elsewhere),
               'SLA access must follow the membership, not the person'
  end

  test "a member reaches the page that hosts the SLA Policy tab" do
    # ProjectsController#settings is gated on :edit_project (require_member), so without
    # :edit_sla_policy claiming projects/settings a granted user would 403 on the page the tab
    # lives on and never see a Settings link — the tab could never be opened.
    grant!

    assert @user.allowed_to?({ controller: 'projects', action: 'settings' }, @project)
  end

  test "the controller/action form agrees with the permission form" do
    # Menu items with a Hash url are gated by allowed_to?(url), not by the permission name, so if
    # these two ever disagree a granted user is let into the dashboard but shown no link to it.
    grant!

    assert @user.allowed_to?({ controller: 'sla_dashboard', action: 'index' }, @project)
  end

  # --- the guarantees the role list must never break -------------------------------------------

  test "a granted user gets nothing on a project with the module disabled" do
    @project.disable_module!(:sla_compliance)
    # disable_module! destroys the EnabledModule row but leaves this instance's enabled_modules
    # association cache populated, so a stale object still reports the module as on. Every real
    # caller loads the project fresh per request; reload to match.
    @project.reload
    grant!

    ALL_PERMISSIONS.each do |permission|
      assert_not @user.allowed_to?(permission, @project), permission.to_s
    end
  end

  test "the builtin Non-member role never grants access, even if configured" do
    # The no-leak guarantee. Role.givable excludes the builtins so the settings form cannot offer
    # this, but a hand-edited settings hash must not turn a public project's SLA dashboard into
    # something every logged-in user can open.
    non_member = Role.non_member
    configure_roles!(non_member)

    assert_not @user.allowed_to?(:view_sla_dashboard, @project),
               'a non-member must not be granted SLA access on a public project'
  end

  test "anonymous is never granted, even holding a configured role somehow" do
    anonymous = User.anonymous
    configure_roles!(@role)

    ALL_PERMISSIONS.each do |permission|
      assert_not Sla::AccessControl.granted?(anonymous, permission, @project), permission.to_s
    end
  end

  test "an unrelated permission is never granted by the role list" do
    grant!

    assert_not Sla::AccessControl.granted?(@user, :edit_project, @project)
    assert_not Sla::AccessControl.granted?(@user, :add_issues, @project)
  end

  test "granted? is false without a project" do
    grant!

    assert_not Sla::AccessControl.granted?(@user, :view_sla_dashboard, nil)
  end

  # --- no regression for the role-permission half (Step 0.2) -----------------------------------

  test "a role that ticks the permission still works without being configured here" do
    role = Role.find(1) # Manager — jsmith (user 2) holds it on project 1
    role.add_permission!(:view_sla_dashboard)
    jsmith = User.find(2)

    assert jsmith.allowed_to?(:view_sla_dashboard, @project)
    assert_not Sla::AccessControl.granted?(jsmith, :view_sla_dashboard, @project),
               'the role permission, not the SLA role list, is what granted this'
  end

  test "an admin still has access with no role configured at all" do
    admin = User.find(1)

    ALL_PERMISSIONS.each do |permission|
      assert admin.allowed_to?(permission, @project), permission.to_s
    end
  end

  test "the role list never takes access away" do
    # It is purely additive: configuring some OTHER role must not downgrade a user whose own role
    # already ticks an SLA permission.
    role = Role.find(1)
    role.add_permission!(:edit_sla_policy)
    configure_roles!(@role)

    assert User.find(2).allowed_to?(:edit_sla_policy, @project)
  end
end
