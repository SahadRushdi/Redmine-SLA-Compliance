require_relative '../test_helper'

# Admin CRUD for the target-duration lookup (feeds the Step 4.4 dropdowns).
class SlaTargetOptionsControllerTest < ActionController::TestCase
  fixtures :users, :email_addresses

  setup do
    @request.session[:user_id] = 1 # admin
  end

  def make_option(attrs = {})
    SlaTargetOption.create!({ target_type: 'response', code: '4h', label: '4 hours',
                              seconds: 14_400, position: 1 }.merge(attrs))
  end

  # The redesigned forms render their own validation summary (app/views/sla_admin/_form_errors)
  # rather than Redmine's `#errorExplanation` block, so core's assert_select_error no longer
  # applies. Same intent: the failing field's message reaches the re-rendered page.
  def assert_sla_form_error(pattern)
    assert_select 'div[role=?] li', 'alert', text: pattern
  end

  test "every action requires admin" do
    @request.session[:user_id] = 2 # jsmith, not admin
    option = make_option

    get :index
    assert_response :forbidden
    get :new
    assert_response :forbidden
    post :create, params: { sla_target_option: { target_type: 'response', code: '1h',
                                                 label: '1 hour', seconds: 3600 } }
    assert_response :forbidden
    get :edit, params: { id: option.id }
    assert_response :forbidden
    put :update, params: { id: option.id, sla_target_option: { label: 'x' } }
    assert_response :forbidden
    delete :destroy, params: { id: option.id }
    assert_response :forbidden
    assert SlaTargetOption.exists?(option.id)
  end

  test "index lists options" do
    make_option
    get :index
    assert_response :success
    assert_select '.sla-admin-rows td', text: '4 hours'
  end

  test "create persists a valid option" do
    assert_difference 'SlaTargetOption.count', 1 do
      post :create, params: { sla_target_option: { target_type: 'resolution', code: '5d',
                                                   label: '5 days', seconds: 432_000,
                                                   position: 3 } }
    end
    assert_redirected_to sla_target_options_path
    option = SlaTargetOption.order(:id).last
    assert_equal 'resolution', option.target_type
    assert_equal 432_000, option.seconds
  end

  test "create rejects an invalid target_type" do
    assert_no_difference 'SlaTargetOption.count' do
      post :create, params: { sla_target_option: { target_type: 'bogus', code: '1h',
                                                   label: '1 hour', seconds: 3600 } }
    end
    assert_response :success # re-rendered form with errors
    assert_sla_form_error(/Target type/)
  end

  test "update persists changes" do
    option = make_option
    put :update, params: { id: option.id, sla_target_option: { label: 'Four hours',
                                                               seconds: 14_400 } }
    assert_redirected_to sla_target_options_path
    assert_equal 'Four hours', option.reload.label
  end

  test "destroy deletes the option" do
    option = make_option
    assert_difference 'SlaTargetOption.count', -1 do
      delete :destroy, params: { id: option.id }
    end
    assert_redirected_to sla_target_options_path
  end

  # --- Best Effort + basis (B4) --------------------------------------------------------------

  test "create persists a Best Effort option with no seconds value" do
    assert_difference 'SlaTargetOption.count', 1 do
      post :create, params: { sla_target_option: { target_type: 'resolution', code: 'be',
                                                   label: 'Best Effort', best_effort: '1' } }
    end
    assert_redirected_to sla_target_options_path
    option = SlaTargetOption.order(:id).last
    assert option.best_effort?
    assert_nil option.seconds
  end

  test "create clears any posted seconds value when Best Effort is checked" do
    post :create, params: { sla_target_option: { target_type: 'resolution', code: 'be',
                                                 label: 'Best Effort', best_effort: '1',
                                                 seconds: '3600' } }
    option = SlaTargetOption.order(:id).last
    assert_nil option.seconds, 'Best Effort must never carry a numeric duration'
  end

  # --- Duration entered as an amount + a unit (2026-08-07) ------------------------------------

  test "create multiplies the posted amount and unit into seconds" do
    post :create, params: {
      sla_target_option: { target_type: 'resolution', label: '4 Hours',
                           duration_amount: '4', duration_unit: 'hours' }
    }
    assert_redirected_to sla_target_options_path
    assert_equal 14_400, SlaTargetOption.order(:id).last.seconds
  end

  # The reason Days is one of the units: the live lookup holds 24h, 48h and 72h targets.
  test "create accepts a duration longer than a day" do
    post :create, params: {
      sla_target_option: { target_type: 'resolution', label: '72 Hours',
                           duration_amount: '3', duration_unit: 'days' }
    }
    assert_equal 259_200, SlaTargetOption.order(:id).last.seconds
  end

  test "the edit form is filled from the stored seconds" do
    option = make_option(code: '48h', label: '48 Hours', seconds: 172_800)
    get :edit, params: { id: option.id }

    assert_select 'input[name=?][value=?]', 'sla_target_option[duration_amount]', '2'
    assert_select 'select[name=?] option[selected][value=?]',
                  'sla_target_option[duration_unit]', 'days'
  end

  test "create derives a code from the label now that the form has no code field" do
    post :create, params: {
      sla_target_option: { target_type: 'response', label: '30 Minutes',
                           duration_amount: '30', duration_unit: 'minutes' }
    }
    assert_redirected_to sla_target_options_path
    option = SlaTargetOption.order(:id).last
    assert_equal '30-minutes', option.code
    assert_equal 1_800, option.seconds
  end

  # Position is no longer on the form; an existing row must keep the ordering it was given.
  test "update leaves a position the form no longer posts untouched" do
    option = make_option(position: 3)
    put :update, params: { id: option.id,
                           sla_target_option: { target_type: 'response', label: '4 Hours',
                                                duration_amount: '4', duration_unit: 'hours' } }

    assert_redirected_to sla_target_options_path
    assert_equal 3, option.reload.position
  end

  # The message names the field as the form labels it — "Duration", not the `seconds` column it is
  # validated on, which nobody types any more (activerecord.attributes.sla_target_option.seconds).
  test "create rejects a non-Best-Effort option with no seconds value" do
    assert_no_difference 'SlaTargetOption.count' do
      post :create, params: { sla_target_option: { target_type: 'response', code: 'x',
                                                   label: 'x' } }
    end
    assert_response :success
    assert_sla_form_error(/Duration/)
  end

  test "a duration left blank on the form is reported, not saved as zero" do
    assert_no_difference 'SlaTargetOption.count' do
      post :create, params: {
        sla_target_option: { target_type: 'response', label: 'Nothing entered',
                             duration_amount: '', duration_unit: 'hours' }
      }
    end
    assert_response :success
    assert_sla_form_error(/Duration/)
  end

  test "create persists the basis" do
    post :create, params: { sla_target_option: { target_type: 'resolution', code: '1bd',
                                                 label: '1 Business Day', seconds: 28_800,
                                                 basis: 'business' } }
    assert_equal 'business', SlaTargetOption.order(:id).last.basis
  end

  test "basis defaults to calendar when not specified" do
    option = make_option
    assert_equal 'calendar', option.basis
  end

  test "create rejects an invalid basis" do
    assert_no_difference 'SlaTargetOption.count' do
      post :create, params: { sla_target_option: { target_type: 'response', code: '1h',
                                                   label: '1 hour', seconds: 3600,
                                                   basis: 'bogus' } }
    end
    assert_response :success
    assert_sla_form_error(/Basis/)
  end
end
