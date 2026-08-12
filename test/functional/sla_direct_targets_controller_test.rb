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

  test 'autosaves the new minute and week units' do
    patch :update_target, params: target_params(mode: 'duration', value: '15', unit: 'minutes')
    assert_response :success
    definition = SlaPolicy.find_by!(project_id: @project.id).sla_definitions.first
    assert_equal 900, definition.response_seconds
    assert_equal 'minutes', definition.response_unit

    patch :update_target, params: target_params(mode: 'duration', value: '2', unit: 'weeks')
    assert_response :success
    definition.reload
    assert_equal 1_209_600, definition.response_seconds
    assert_equal 'weeks', definition.response_unit
  end

  test 'rejects a decimal duration without changing the saved target' do
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    definition = policy.sla_definitions.create!(tracker_id: @tracker.id,
                                                priority_id: @priority.id,
                                                response_seconds: 3600,
                                                response_unit: 'hours')

    patch :update_target, params: target_params(mode: 'duration', value: '1.5', unit: 'hours')

    assert_response :unprocessable_entity
    assert_equal 'Enter a whole number. Decimal values are not allowed.', response.parsed_body['error']
    assert_equal 3600, definition.reload.response_seconds
  end

  test 'legacy decimal targets do not render as native-invalid form controls' do
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true,
                               selected_tracker_ids: [@tracker.id])
    policy.sla_definitions.create!(tracker_id: @tracker.id, priority_id: @priority.id,
                                   response_seconds: 1440, response_unit: 'hours')

    get :edit, params: { project_id: @project.id, tracker_id: @tracker.id }, format: 'js', xhr: true

    assert_response :success
    rendered_html = response.body.gsub('\\"', '"')
    assert_includes rendered_html, 'input type="text" value="0.4" inputmode="numeric"'
    refute_includes rendered_html, 'input type="number"'
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

  test 'clones every priority target from a configured tracker into the selected tracker' do
    target_tracker = @project.trackers.where.not(id: @tracker.id).first
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true,
                               selected_tracker_ids: [@tracker.id, target_tracker.id])
    source = policy.sla_definitions.create!(tracker_id: @tracker.id, priority_id: @priority.id,
                                            response_seconds: 14_400, response_unit: 'hours',
                                            resolution_best_effort: true)
    policy.sla_definitions.create!(tracker_id: target_tracker.id, priority_id: @priority.id,
                                   response_seconds: 3600)

    patch :clone_tracker, params: { project_id: @project.id, source_tracker_id: @tracker.id,
                                    target_tracker_id: target_tracker.id }

    assert_response :success
    copied = policy.sla_definitions.find_by!(tracker_id: target_tracker.id,
                                             priority_id: @priority.id)
    assert_equal source.response_seconds, copied.response_seconds
    assert_equal 'hours', copied.response_unit
    assert copied.resolution_best_effort?
    assert_equal 1, policy.sla_definitions.where(tracker_id: @tracker.id).count,
                 'cloning must not alter the source tracker'
  end

  test 'rejects cloning into an unselected tracker' do
    target_tracker = @project.trackers.where.not(id: @tracker.id).first
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true,
                               selected_tracker_ids: [@tracker.id])
    policy.sla_definitions.create!(tracker_id: @tracker.id, priority_id: @priority.id,
                                   response_seconds: 3600)

    patch :clone_tracker, params: { project_id: @project.id, source_tracker_id: @tracker.id,
                                    target_tracker_id: target_tracker.id }

    assert_response :unprocessable_entity
    assert_empty policy.sla_definitions.where(tracker_id: target_tracker.id)
  end

  private

  def target_params(overrides = {})
    { project_id: @project.id, tracker_id: @tracker.id, priority_id: @priority.id,
      target_type: 'response' }.merge(overrides)
  end
end
