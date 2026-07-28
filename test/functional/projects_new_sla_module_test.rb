require_relative '../test_helper'

# Step 6A.4 — the New Project form arrives with the SLA Compliance module already ticked when the
# project is being created under a parent that has it.
#
# Renders Redmine's own form rather than testing the patch in isolation, because the thing being
# asserted IS the rendered checkbox: the patch only sets a default, and a default that the form
# doesn't pick up would be no fix at all.
class ProjectsNewSlaModuleTest < ActionController::TestCase
  tests ProjectsController

  fixtures :projects, :projects_trackers, :trackers, :issue_statuses, :workflows,
           :enumerations, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules

  CHECKBOX = 'input#project_enabled_module_names_sla_compliance'

  setup do
    @parent = Project.find(1)
    @request.session[:user_id] = 1 # admin — may select project modules
    Setting.default_projects_modules = %w[issue_tracking]
  end

  teardown do
    Setting.clear_cache
  end

  test 'the SLA module is pre-ticked for a subproject of an SLA-enabled parent' do
    @parent.enable_module!(:sla_compliance)

    get :new, params: { parent_id: @parent.id }

    assert_response :success
    assert_select "#{CHECKBOX}[checked]"
  end

  # The parent decides. Ticking it under a project that does not track SLAs would be inventing a
  # default nobody asked for.
  test 'the SLA module is left alone for a subproject of a parent without it' do
    get :new, params: { parent_id: @parent.id }

    assert_response :success
    assert_select CHECKBOX
    assert_select "#{CHECKBOX}[checked]", 0
  end

  test 'the SLA module is left alone for a top-level project' do
    @parent.enable_module!(:sla_compliance)

    get :new

    assert_response :success
    assert_select "#{CHECKBOX}[checked]", 0
  end

  # The re-render after a validation failure runs through #create, which this patch does not touch
  # — so a box the user deliberately unticked stays unticked instead of being helpfully restored.
  test 'unticking the module survives a failed create' do
    @parent.enable_module!(:sla_compliance)

    post :create, params: { project: { name: '', identifier: '',
                                       parent_id: @parent.id.to_s,
                                       enabled_module_names: ['issue_tracking'] } }

    assert_response :success # re-rendered form, not a redirect
    assert_select "#{CHECKBOX}[checked]", 0
  end

  test 'a subproject created from the pre-ticked form has the module enabled' do
    @parent.enable_module!(:sla_compliance)

    post :create, params: { project: { name: 'SLA child', identifier: 'sla-child',
                                       parent_id: @parent.id.to_s,
                                       enabled_module_names: %w[issue_tracking sla_compliance] } }

    child = Project.find_by(identifier: 'sla-child')
    assert child.present?
    assert child.module_enabled?(:sla_compliance)
  end
end
