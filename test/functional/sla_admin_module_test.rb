require_relative '../test_helper'

class SlaAdminModuleTest < ActionController::TestCase
  tests SlaSettingsController
  fixtures :users, :email_addresses

  setup { @request.session[:user_id] = 1 }

  test 'admin module contains General as its only section' do
    get :show

    assert_response :success
    assert_select '[data-sla-admin-section]', 1
    assert_select '[data-sla-admin-section="general"]', 1
    assert_select 'a', text: /Target options/i, count: 0
    assert_select 'a', text: /Business calendars/i, count: 0
  end

  test 'non administrators cannot access the admin module' do
    @request.session[:user_id] = 2
    get :show
    assert_response :forbidden
  end
end
