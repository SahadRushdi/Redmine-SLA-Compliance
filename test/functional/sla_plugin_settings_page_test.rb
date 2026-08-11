# frozen_string_literal: true

require_relative '../test_helper'

# Step 5.1 — the admin screen itself: Administration → SLA Compliance → General → SLA access roles.
#
# Renders and saves through SlaSettingsController, the plugin's own page. (It used to be Redmine's
# SettingsController#plugin; that host was dropped on 2026-08-05 because it could never highlight
# the module's own sidebar entry — see SlaSettingsController.) This is the end-to-end proof of the
# admin flow: the page renders (helper wiring, routes, PluginSettings readers), the picker carries
# what the Tom Select JS needs, and a saved role round-trips into a real permission.
#
# The control was two per-USER allow-lists ("SLA viewers" / "SLA managers") on their own Access
# control section until 2026-08-06; it is now one role picker on General.
class SlaPluginSettingsPageTest < ActionController::TestCase
  tests SlaSettingsController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :enumerations

  PICKER = 'select#settings_sla_access_role_ids'

  setup do
    @request.session[:user_id] = 1 # admin
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  def get_settings_page
    get :show, params: { section: 'general' }
  end

  # --- rendering ------------------------------------------------------------------------------

  test "the settings page renders the role picker as a multi-select" do
    get_settings_page

    assert_response :success
    assert_select "#{PICKER}[multiple]", 1
    assert_select "#{PICKER}[name='settings[sla_access_role_ids][]']", 1
  end

  test "the picker offers every givable role and nothing else" do
    get_settings_page

    Role.givable.each do |role|
      assert_select "#{PICKER} option[value='#{role.id}']", 1, role.name
    end
    # The builtin Non-member / Anonymous roles must never be offerable: granting one would hand
    # SLA access to everyone who can open the project, member or not.
    [Role.non_member, Role.anonymous].each do |builtin|
      assert_select "#{PICKER} option[value='#{builtin.id}']", 0, builtin.name
    end
  end

  test "the picker is a Tom Select chip control, not a bare multi-select" do
    # Without this attribute the control still renders, but as an unstyled native multi-select
    # with no chips and no search — a silent degradation nothing else here would catch.
    get_settings_page

    assert_select "#{PICKER}[data-sla-chips]", 1
  end

  test "the scoped assets and the module JS reach the page" do
    get_settings_page

    assert_select 'script[src*="sla_admin"]', 1
    assert_select 'script[src*="tom-select"]', 1
    assert_select 'link[href*="tailwind.output"]', 1
  end

  test "the picker posts a blank sentinel so clearing every chip persists" do
    get_settings_page

    assert_select "input[type=hidden][name='settings[sla_access_role_ids][]'][value='']", 1,
                  'the list must still post [] when emptied'
  end

  test "already-configured roles come back selected" do
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => %w[1 3] }

    get_settings_page

    assert_response :success
    assert_select "#{PICKER} option[value='1'][selected]", 1
    assert_select "#{PICKER} option[value='3'][selected]", 1
    assert_select "#{PICKER} option[value='2'][selected]", 0,
                  'an unconfigured role must not come back selected'
  end

  test "a stale id for a deleted role does not break the page" do
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => %w[1 999999] }

    get_settings_page

    assert_response :success
    assert_select "#{PICKER} option[value='1'][selected]", 1
    assert_select "#{PICKER} option[value='999999']", 0
  end

  test "the Access control section is gone from the sidebar" do
    get_settings_page

    assert_response :success
    assert_select '[data-sla-admin-section]', 2,
                  'General and Notifications are the two panel sections; access remains folded in'
    assert_select "[data-sla-admin-section='access']", 0
    assert_select "[data-sla-admin-panel='access']", 0
  end

  test "the page is admin-only" do
    @request.session[:user_id] = 2 # jsmith
    get_settings_page
    assert_response :forbidden
  end

  # --- saving ---------------------------------------------------------------------------------

  test "saving persists the selected roles" do
    patch :update, params: { settings: { 'sla_access_role_ids' => ['', '1', '3'] } }

    assert_redirected_to sla_settings_path
    assert_equal [1, 3], Sla::PluginSettings.access_role_ids
  end

  test "saving with every chip removed clears the list" do
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => %w[1] }

    # What the form posts once the admin removes every chip: the sentinel alone.
    patch :update, params: { settings: { 'sla_access_role_ids' => [''] } }

    assert_equal [], Sla::PluginSettings.access_role_ids
  end

  test "saving drops the retired per-user allow-lists from the stored hash" do
    # #update merges over the stored settings, so without RETIRED_SETTINGS these keys would sit
    # in a production settings hash forever. Nothing reads them, but leaving stale grants behind
    # is not a state to keep.
    Setting.plugin_redmine_sla_compliance = {
      'sla_viewer_user_ids' => %w[4],
      'sla_manager_user_ids' => %w[2],
      'sweep_interval_minutes' => '20'
    }

    patch :update, params: { settings: { 'sla_access_role_ids' => ['', '1'] } }

    stored = Setting.plugin_redmine_sla_compliance
    assert_not stored.key?('sla_viewer_user_ids')
    assert_not stored.key?('sla_manager_user_ids')
    assert_not stored.key?('sweep_interval_minutes')
  end

  # --- the whole point: saving here grants access there ----------------------------------------

  test "naming a role on this page grants its members SLA access immediately" do
    project = Project.find(1)
    project.enable_module!(:sla_compliance)
    role = Role.create!(name: 'SLA Access Test Role', permissions: [])
    rhill = User.find(4) # no role, no membership until now
    Member.create!(principal: rhill, project: project, roles: [role])

    assert_not rhill.allowed_to?(:view_sla_dashboard, project), 'precondition: no access'

    patch :update, params: { settings: { 'sla_access_role_ids' => ['', role.id.to_s] } }

    assert rhill.allowed_to?(:view_sla_dashboard, project),
           'a saved grant must apply with no restart'
    assert rhill.allowed_to?(:edit_sla_policy, project),
           'the dashboard and the policy settings are one grant now, not two'
  end

  test "naming a role grants every member who holds it, with no per-user administration" do
    project = Project.find(1)
    project.enable_module!(:sla_compliance)
    role = Role.create!(name: 'SLA Access Test Role', permissions: [])
    [4, 7].each { |id| Member.create!(principal: User.find(id), project: project, roles: [role]) }

    patch :update, params: { settings: { 'sla_access_role_ids' => ['', role.id.to_s] } }

    [4, 7].each do |id|
      assert User.find(id).allowed_to?(:edit_sla_policy, project), "user #{id}"
    end
  end
end
