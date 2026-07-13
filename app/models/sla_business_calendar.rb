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

  validates :name, presence: true, length: { maximum: 255 }
  validate :working_days_are_valid
  validate :work_times_present_together
  validate :holidays_are_valid

  private

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
