# frozen_string_literal: true

# Working days / hours / holidays used by the business-hours calculation (Phase 2.3).
# working_days is a JSON array of weekday numbers (1 = Monday .. 7 = Sunday, ISO-8601);
# holidays is a JSON array of ISO date strings.
class SlaBusinessCalendar < ActiveRecord::Base
  self.table_name = 'sla_business_calendars'

  serialize :working_days, JSON
  serialize :holidays, JSON

  # restrict (not nullify): nullifying the FK would leave a business-hours policy with no
  # calendar, which the engine cannot measure against (Sla::BusinessHoursCalculator). Block the
  # delete instead so the admin must detach the calendar from its policies first.
  has_many :sla_policies, foreign_key: :business_calendar_id, dependent: :restrict_with_error

  # The one shape Sla::BusinessHoursCalculator#parse_hhmm can read back. Anything stored that does
  # not match it silently degrades to 00:00 there — "banana" and "25:00" both measure as midnight
  # — so the format is validated on the way in rather than trusted on the way out.
  WORK_TIME_FORMAT = /\A([01]\d|2[0-3]):[0-5]\d\z/.freeze

  validates :name, presence: true, length: { maximum: 255 }
  validate :working_days_are_valid
  validate :work_times_present_together
  validate :work_times_are_well_formed
  validate :holidays_are_valid

  before_validation :normalize_work_times

  # Returns the stored 'HH:MM' for the shapes a time value can arrive in: a bare hour ("9" → 09:00),
  # four digits ("0930" → 09:30), three ("930" → 09:30) and an unpadded clock ("9:5" → 09:05).
  # Input it cannot read is handed back untouched for the format validation to report, so a typo is
  # never quietly reinterpreted as a working hour.
  #
  # The admin form posts from a native time picker, which can only send a padded HH:MM — but this
  # is not therefore dead. It normalises payloads that do not come from that form (a script, a
  # bookmarked older form), and the form itself calls it to RENDER: a time input shows nothing at
  # all for a value it cannot parse, so rows written before the format was validated would open
  # blank and be wiped by the next save.
  def self.normalized_work_time(value)
    raw = value.to_s.strip
    return raw if raw.empty?

    hours, minutes =
      if raw.include?(':')
        raw.split(':', 2)
      else
        case raw.length
        when 1, 2 then [raw, '0']
        when 3, 4 then [raw[0..-3], raw[-2..]]
        else return raw
        end
      end

    return raw unless hours.match?(/\A\d{1,2}\z/) && minutes.match?(/\A\d{1,2}\z/)

    format('%02d:%02d', hours.to_i, minutes.to_i)
  end

  private

  # `.presence` keeps a cleared field NULL rather than turning it into "", which
  # work_times_present_together reads as absent either way but which would make "unset" two
  # different values in the table.
  def normalize_work_times
    self.work_start_time = self.class.normalized_work_time(work_start_time).presence
    self.work_end_time   = self.class.normalized_work_time(work_end_time).presence
  end

  def work_times_are_well_formed
    %i[work_start_time work_end_time].each do |attribute|
      value = send(attribute)
      errors.add(attribute, :invalid) if value.present? && !value.match?(WORK_TIME_FORMAT)
    end
  end

  def working_days_are_valid
    return if working_days.blank?
    unless working_days.is_a?(Array) && working_days.all? { |d| (1..7).cover?(d.to_i) }
      errors.add(:working_days, :invalid)
    end
  end

  def work_times_present_together
    if work_start_time.present? ^ work_end_time.present?
      errors.add(:base, 'work_start_time and work_end_time must both be set')
    end
  end

  # The engine (Sla::BusinessHoursCalculator) expects ISO date strings; reject anything else
  # at write time so bad admin input can't silently corrupt SLA math.
  def holidays_are_valid
    return if holidays.blank?
    valid = holidays.is_a?(Array) && holidays.all? do |h|
      Date.iso8601(h.to_s)
      true
    rescue ArgumentError, TypeError
      false
    end
    errors.add(:holidays, :invalid) unless valid
  end
end
