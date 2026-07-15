# frozen_string_literal: true

require_relative '../test_helper'

# Step 5.1 — "a non-permitted role sees neither the tab nor the dashboard; an admin can grant
# access to a chosen role and it takes effect."
#
# This covers the dashboard half end-to-end through the real controller, including the project
# menu entry: a user who cannot open the dashboard must not be shown a link to it either.
class SlaDashboardControllerTest < ActionController::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses, :enumerations

  setup do
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    @role = Role.find(1) # Manager — jsmith (user 2)
    # rhill: active, no membership anywhere, no role. Anything they can do came from the list.
    @user = User.find(4)
    @request.session[:user_id] = @user.id
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  def list!(list, *user_ids)
    Setting.plugin_redmine_sla_compliance = {
      "sla_#{list}_user_ids" => user_ids.map(&:to_s)
    }
  end

  # --- denied ---------------------------------------------------------------------------------

  test "a user with no role and no listing cannot open the dashboard" do
    get :index, params: { project_id: @project.id }
    assert_response :forbidden
  end

  test "a role without view_sla_dashboard cannot open the dashboard" do
    @request.session[:user_id] = 2 # jsmith, Manager on project 1, but no SLA permission
    get :index, params: { project_id: @project.id }
    assert_response :forbidden
  end

  # --- granted --------------------------------------------------------------------------------

  test "a listed viewer opens the dashboard with no role and no membership" do
    list!(:viewer, @user.id)

    get :index, params: { project_id: @project.id }

    assert_response :success
    assert_select '.sla-plugin'
  end

  test "a listed manager opens the dashboard too" do
    list!(:manager, @user.id)

    get :index, params: { project_id: @project.id }
    assert_response :success
  end

  test "a granted role opens the dashboard" do
    @role.add_permission!(:view_sla_dashboard)
    @request.session[:user_id] = 2

    get :index, params: { project_id: @project.id }
    assert_response :success
  end

  # --- the "takes effect" half of the Done when -----------------------------------------------

  test "granting and revoking a user takes effect immediately, with no restart" do
    get :index, params: { project_id: @project.id }
    assert_response :forbidden, 'precondition: not listed yet'

    list!(:viewer, @user.id)
    get :index, params: { project_id: @project.id }
    assert_response :success, 'a saved grant must apply on the very next request'

    Setting.plugin_redmine_sla_compliance = {}
    get :index, params: { project_id: @project.id }
    assert_response :forbidden, 'revoking must apply just as immediately'
  end

  test "several users can be granted at once" do
    list!(:viewer, 4, 7) # rhill and someone, in one saved list

    get :index, params: { project_id: @project.id }
    assert_response :success

    @request.session[:user_id] = 7
    get :index, params: { project_id: @project.id }
    assert_response :success
  end

  # --- the guarantees -------------------------------------------------------------------------

  test "a listed viewer is still refused when the module is disabled" do
    @project.disable_module!(:sla_compliance)
    list!(:viewer, @user.id)

    get :index, params: { project_id: @project.id }
    assert_response :forbidden
  end

  test "a listed viewer cannot see a private project they are not a member of" do
    private_project = Project.find(2) # OnlineStore — rhill is not a member
    private_project.enable_module!(:sla_compliance)
    list!(:viewer, @user.id)

    get :index, params: { project_id: private_project.id }

    assert_response :forbidden
  end

  # --- the menu entry: seeing the dashboard means being shown the way to it --------------------

  class SlaDashboardMenuTest < ActionController::TestCase
    tests ProjectsController

    fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
             :enabled_modules, :trackers, :projects_trackers, :issue_statuses, :enumerations

    setup do
      @project = Project.find(1)
      @project.enable_module!(:sla_compliance)
      @request.session[:user_id] = 4 # rhill
      Setting.plugin_redmine_sla_compliance = {}
    end

    teardown do
      Setting.plugin_redmine_sla_compliance = {}
    end

    test "the SLA menu entry is hidden from a user with no role and no listing" do
      get :show, params: { id: @project.identifier }
      assert_response :success
      assert_select '#main-menu a.sla-compliance', 0
    end

    test "a listed viewer is shown the SLA menu entry" do
      Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => ['4'] }

      get :show, params: { id: @project.identifier }

      assert_response :success
      assert_select '#main-menu a.sla-compliance'
    end
  end
end
