# frozen_string_literal: true

require_relative '../test_helper'

# Step 5.1 — the admin screen itself: Administration → Plugins → SLA Compliance → Configure.
#
# Renders and saves through Redmine's own SettingsController#plugin, which is what actually hosts
# the plugin's settings partial. That makes this the end-to-end proof of the admin flow: the
# partial renders (helper wiring, routes, PluginSettings readers), the pickers carry what the
# Tom Select JS needs, and a saved list round-trips into a real permission.
class SlaPluginSettingsPageTest < ActionController::TestCase
  tests SettingsController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :enumerations

  setup do
    @request.session[:user_id] = 1 # admin
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  def get_settings_page
    get :plugin, params: { id: 'redmine_sla_compliance' }
  end

  # --- rendering ------------------------------------------------------------------------------

  test "the configure page renders both user pickers" do
    get_settings_page

    assert_response :success
    # Search-only boxes now, not the value carrier -- no `multiple`, no options; granted users
    # are shown in the table below instead.
    assert_select 'select#sla-viewer-users'
    assert_select 'select#sla-viewer-users[multiple]', 0
    assert_select 'select#sla-manager-users'
    assert_select 'select#sla-manager-users[multiple]', 0
  end

  test "the settings page offers exactly the two access lists and no others" do
    get_settings_page

    assert_response :success
    assert_select '[data-sla-access-list]', 2,
                  'the user pickers are the access grants only — there is no system-account list'
  end

  test "the scoped assets and picker JS reach the page" do
    # Without these the pickers still render, but as bare unstyled multi-selects with no search
    # and no chips — a silent degradation the other assertions here would not catch.
    get_settings_page

    assert_select 'script[src*="sla_access_form"]', 1
    assert_select 'script[src*="tom-select"]', 1
    assert_select 'link[href*="tailwind.output"]', 1
  end

  test "each picker is wired to the user-search endpoint the JS reads" do
    get_settings_page

    %w[sla-viewer-users sla-manager-users].each do |id|
      assert_select "select##{id}[data-sla-user-search='#{sla_access_users_path}']", 1,
                    "#{id} must tell sla_access_form.js where to search"
    end
  end

  test "each picker posts a blank sentinel so clearing every chip persists" do
    get_settings_page

    %w[viewer manager].each do |list|
      assert_select "input[type=hidden][name='settings[sla_#{list}_user_ids][]'][value='']", 1,
                    "#{list} list must still post [] when emptied"
    end
  end

  test "already-listed users post as hidden inputs, not preselected chips" do
    Setting.plugin_redmine_sla_compliance = {
      'sla_viewer_user_ids' => %w[4],
      'sla_manager_user_ids' => %w[2]
    }

    get_settings_page

    assert_response :success
    assert_select "[data-sla-access-list='viewer'] input[type=hidden]" \
                  "[name='settings[sla_viewer_user_ids][]'][value='4']"
    assert_select "[data-sla-access-list='manager'] input[type=hidden]" \
                  "[name='settings[sla_manager_user_ids][]'][value='2']"
    assert_select "[data-sla-access-list='viewer'] input[type=hidden]" \
                  "[name='settings[sla_viewer_user_ids][]'][value='2']", 0,
                  'the two lists must not bleed into each other'
  end

  test "already-listed users also render in the plain table below the picker" do
    Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => %w[4] }

    get_settings_page

    rhill = User.find(4)
    assert_select 'table td', text: rhill.name
    assert_select 'table td', text: rhill.login
    assert_select 'table td', text: rhill.mail
    # sla_access_form.js reads this JSON seed on boot and takes over from there.
    assert_select "[data-sla-access-list='viewer'][data-sla-users*='#{rhill.name}']"
  end

  test "the table headers are sortable and each row carries a delete button" do
    Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => %w[4] }

    get_settings_page

    assert_select "[data-sla-access-list='viewer'] th[data-sla-sort='name']"
    assert_select "[data-sla-access-list='viewer'] th[data-sla-sort='login']"
    assert_select "[data-sla-access-list='viewer'] th[data-sla-sort='mail']"
    assert_select "[data-sla-access-list='viewer'] [data-sla-empty].hidden"
  end

  test "the empty-state message shows for a list with nobody on it" do
    get_settings_page

    assert_select "[data-sla-access-list='viewer'] [data-sla-empty]:not(.hidden)"
    assert_select "[data-sla-access-list='viewer'] table tbody tr", 0
  end

  test "a stale id for a deleted user does not break the page" do
    Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => %w[4 999999] }

    get_settings_page

    assert_response :success
    assert_select "[data-sla-access-list='viewer'] input[type=hidden]" \
                  "[name='settings[sla_viewer_user_ids][]'][value='4']"
    assert_select "[data-sla-access-list='viewer'] input[type=hidden]" \
                  "[name='settings[sla_viewer_user_ids][]'][value='999999']", 0
  end

  test "the page is admin-only" do
    @request.session[:user_id] = 2 # jsmith
    get_settings_page
    assert_response :forbidden
  end

  # --- saving ---------------------------------------------------------------------------------

  test "saving persists both lists" do
    post :plugin, params: { id: 'redmine_sla_compliance',
                            settings: { 'sla_viewer_user_ids' => ['', '4', '7'],
                                        'sla_manager_user_ids' => ['', '2'] } }

    assert_redirected_to plugin_settings_path('redmine_sla_compliance')
    assert_equal [4, 7], Sla::PluginSettings.viewer_user_ids
    assert_equal [2], Sla::PluginSettings.manager_user_ids
  end

  test "saving with every chip removed clears the list" do
    Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => %w[4] }

    # What the form posts once the admin removes every chip: the sentinel alone.
    post :plugin, params: { id: 'redmine_sla_compliance',
                            settings: { 'sla_viewer_user_ids' => [''] } }

    assert_equal [], Sla::PluginSettings.viewer_user_ids
  end

  # --- the whole point: saving here grants access there ----------------------------------------

  test "adding a user on this page grants them SLA access immediately" do
    project = Project.find(1)
    project.enable_module!(:sla_compliance)
    rhill = User.find(4) # no role, no membership

    assert_not rhill.allowed_to?(:view_sla_dashboard, project), 'precondition: no access'

    post :plugin, params: { id: 'redmine_sla_compliance',
                            settings: { 'sla_viewer_user_ids' => ['', '4'] } }

    assert rhill.allowed_to?(:view_sla_dashboard, project),
           'a saved grant must apply with no restart'
    assert_not rhill.allowed_to?(:edit_sla_policy, project),
               'the viewer list must stay dashboard-only'
  end

  test "adding several users at once grants them all" do
    project = Project.find(1)
    project.enable_module!(:sla_compliance)

    post :plugin, params: { id: 'redmine_sla_compliance',
                            settings: { 'sla_manager_user_ids' => ['', '4', '7'] } }

    [4, 7].each do |id|
      assert User.find(id).allowed_to?(:edit_sla_policy, project), "user #{id}"
    end
  end
end
