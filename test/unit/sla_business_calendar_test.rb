# frozen_string_literal: true

require_relative '../test_helper'

# A business calendar in use by a policy must not be deletable — nullifying the FK would leave a
# business-hours policy with no calendar, which the engine cannot measure against.
class SlaBusinessCalendarTest < ActiveSupport::TestCase
  fixtures :projects

  def make_calendar(attrs = {})
    SlaBusinessCalendar.create!({ name: 'Business Week', working_days: [1, 2, 3, 4, 5],
                                  work_start_time: '09:00', work_end_time: '17:00',
                                  holidays: [] }.merge(attrs))
  end

  # Working hours are typed as bare digits on the admin form. This is the rule that turns them into
  # the one shape Sla::BusinessHoursCalculator#parse_hhmm reads — assets/javascripts/sla_admin.js
  # only mirrors it, so every case here has to hold with no JavaScript involved.
  NORMALISED_TIMES = {
    '9' => '09:00',        # bare hour
    '09' => '09:00',
    '17' => '17:00',
    '930' => '09:30',      # three digits: H MM
    '0930' => '09:30',     # four digits: HH MM
    '1730' => '17:30',
    '9:5' => '09:05',      # unpadded clock
    '9:00' => '09:00',
    ' 9 ' => '09:00',      # stray whitespace from a paste
    '09:00' => '09:00'     # already stored shape, unchanged
  }.freeze

  test "working hours typed as digits are stored as HH:MM" do
    NORMALISED_TIMES.each do |typed, stored|
      calendar = make_calendar(work_start_time: typed, work_end_time: '18:00')
      assert_equal stored, calendar.work_start_time, "#{typed.inspect} should normalise"
    end
  end

  test "input that is not a time is reported, never reinterpreted as an hour" do
    ['banana', '25:00', '09:60', '12345', '::'].each do |bad|
      calendar = SlaBusinessCalendar.new(name: 'Bad', working_days: [1],
                                         work_start_time: bad, work_end_time: '17:00')

      assert_not calendar.valid?, "#{bad.inspect} should be rejected"
      assert calendar.errors[:work_start_time].present?,
             "#{bad.inspect} should fail on work_start_time"
    end
  end

  test "a cleared working hour stays NULL rather than becoming an empty string" do
    calendar = make_calendar
    calendar.update!(work_start_time: '  ', work_end_time: '')

    assert_nil calendar.reload.work_start_time
    assert_nil calendar.work_end_time
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
