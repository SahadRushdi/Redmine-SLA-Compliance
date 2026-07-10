# frozen_string_literal: true

require_relative '../test_helper'

# A business calendar in use by a policy must not be deletable — nullifying the FK would leave a
# business-hours policy with no calendar, which the engine cannot measure against.
class SlaBusinessCalendarTest < ActiveSupport::TestCase
  fixtures :projects

  def make_calendar
    SlaBusinessCalendar.create!(name: 'Business Week', working_days: [1, 2, 3, 4, 5],
                                work_start_time: '09:00', work_end_time: '17:00', holidays: [])
  end

  test "a calendar with no referencing policy can be destroyed" do
    calendar = make_calendar
    assert calendar.destroy
    assert_not SlaBusinessCalendar.exists?(calendar.id)
  end

  test "a calendar referenced by a policy cannot be destroyed" do
    calendar = make_calendar
    SlaPolicy.create!(project_id: Project.find(1).id, enabled: true,
                      coverage_hours: 'business_hours', business_calendar_id: calendar.id)

    assert_not calendar.destroy, 'expected destroy to be blocked while in use'
    assert calendar.errors.present?
    assert SlaBusinessCalendar.exists?(calendar.id), 'calendar should still exist'
  end
end
