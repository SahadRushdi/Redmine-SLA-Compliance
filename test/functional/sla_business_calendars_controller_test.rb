require_relative '../test_helper'

# Admin CRUD for business calendars (feeds Business Hours coverage, Step 4.2).
class SlaBusinessCalendarsControllerTest < ActionController::TestCase
  fixtures :users, :email_addresses, :projects

  setup do
    @request.session[:user_id] = 1 # admin
  end

  def make_calendar(attrs = {})
    SlaBusinessCalendar.create!({ name: 'Standard week', working_days: [1, 2, 3, 4, 5],
                                  work_start_time: '09:00',
                                  work_end_time: '17:00' }.merge(attrs))
  end

  # The redesigned forms render their own validation summary (app/views/sla_admin/_form_errors)
  # rather than Redmine's `#errorExplanation` block, so core's assert_select_error no longer
  # applies. Same intent: the failing field's message reaches the re-rendered page.
  def assert_sla_form_error(pattern)
    assert_select 'div[role=?] li', 'alert', text: pattern
  end

  test "every action requires admin" do
    @request.session[:user_id] = 2
    calendar = make_calendar

    get :index
    assert_response :forbidden
    get :new
    assert_response :forbidden
    post :create, params: { sla_business_calendar: { name: 'x' } }
    assert_response :forbidden
    get :edit, params: { id: calendar.id }
    assert_response :forbidden
    put :update, params: { id: calendar.id, sla_business_calendar: { name: 'x' } }
    assert_response :forbidden
    delete :destroy, params: { id: calendar.id }
    assert_response :forbidden
    assert SlaBusinessCalendar.exists?(calendar.id)
  end

  test "create parses weekday checkboxes and holidays textarea into JSON arrays" do
    assert_difference 'SlaBusinessCalendar.count', 1 do
      post :create, params: {
        sla_business_calendar: {
          name: 'Support hours',
          working_days: %w[1 2 3 4 5],
          work_start_time: '08:30',
          work_end_time: '17:30',
          holidays_text: "2026-12-25\n2026-01-01\n\n2026-04-03"
        }
      }
    end
    assert_redirected_to sla_business_calendars_path
    calendar = SlaBusinessCalendar.order(:id).last
    assert_equal [1, 2, 3, 4, 5], calendar.working_days
    assert_equal %w[2026-12-25 2026-01-01 2026-04-03], calendar.holidays
    assert_equal '08:30', calendar.work_start_time
  end

  test "create rejects malformed holiday dates" do
    assert_no_difference 'SlaBusinessCalendar.count' do
      post :create, params: {
        sla_business_calendar: { name: 'Bad', working_days: %w[1],
                                 holidays_text: "not-a-date" }
      }
    end
    assert_response :success
    assert_sla_form_error(/Holidays/)
  end

  test "update persists changes" do
    calendar = make_calendar
    put :update, params: { id: calendar.id,
                           sla_business_calendar: { name: 'Renamed',
                                                    working_days: %w[6 7],
                                                    work_start_time: '09:00',
                                                    work_end_time: '17:00',
                                                    holidays_text: '' } }
    assert_redirected_to sla_business_calendars_path
    calendar.reload
    assert_equal 'Renamed', calendar.name
    assert_equal [6, 7], calendar.working_days
    assert_equal [], calendar.holidays
  end

  test "destroy is blocked while a policy references the calendar" do
    calendar = make_calendar
    SlaPolicy.create!(project_id: 1, enabled: true, coverage_hours: 'business_hours',
                      business_calendar_id: calendar.id)

    assert_no_difference 'SlaBusinessCalendar.count' do
      delete :destroy, params: { id: calendar.id }
    end
    assert_redirected_to sla_business_calendars_path
    assert flash[:error].present?
  end

  test "destroy deletes an unreferenced calendar" do
    calendar = make_calendar
    assert_difference 'SlaBusinessCalendar.count', -1 do
      delete :destroy, params: { id: calendar.id }
    end
  end
end
