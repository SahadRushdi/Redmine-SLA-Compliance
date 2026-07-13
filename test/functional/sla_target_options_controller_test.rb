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
    assert_select 'table.list td', text: '4 hours'
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
    assert_select_error(/Target type/)
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
end
