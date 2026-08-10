require_relative '../test_helper'

class SlaDirectTargetsControllerTest < ActionController::TestCase
  tests SlaPoliciesController
  include ActiveJob::TestHelper

  fixtures :projects, :projects_trackers, :trackers, :enumerations, :users, :email_addresses,
           :roles, :members, :member_roles, :enabled_modules

  setup do
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    Role.find(1).add_permission!(:edit_sla_policy)
    @request.session[:user_id] = 2
    @tracker = @project.trackers.first
    @priority = IssuePriority.active.first
  end

  test 'autosaves a direct duration and returns its generated label' do
    patch :update_target, params: target_params(mode: 'duration', value: '72', unit: 'hours')

    assert_response :success
    definition = SlaPolicy.find_by!(project_id: @project.id).sla_definitions.find_by!(
      tracker_id: @tracker.id, priority_id: @priority.id
    )
    assert_equal 259_200, definition.response_seconds
    assert_equal '72 Hours', response.parsed_body['display']
    assert_equal 'hours', definition.response_unit
  end

  test 'autosaves Best Effort without a numeric deadline' do
    patch :update_target, params: target_params(mode: 'best_effort')

    assert_response :success
    definition = SlaPolicy.find_by!(project_id: @project.id).sla_definitions.first
    assert definition.response_best_effort?
    assert_nil definition.response_seconds
  end

  test 'clearing the last target removes the empty definition' do
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    policy.sla_definitions.create!(tracker_id: @tracker.id, priority_id: @priority.id,
                                   response_seconds: 3600)

    patch :update_target, params: target_params(mode: 'unset')

    assert_response :success
    assert_empty policy.sla_definitions.reload
  end

  test 'rejects targets outside the live project tracker and priority configuration' do
    patch :update_target, params: target_params(tracker_id: 999_999, mode: 'duration',
                                                value: '1', unit: 'hours')

    assert_response :unprocessable_entity
    assert_nil SlaPolicy.find_by(project_id: @project.id)
  end

  private

  def target_params(overrides = {})
    { project_id: @project.id, tracker_id: @tracker.id, priority_id: @priority.id,
      target_type: 'response' }.merge(overrides)
  end
end
