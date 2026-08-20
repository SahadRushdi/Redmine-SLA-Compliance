# frozen_string_literal: true

require_relative '../test_helper'

class SlaComplianceHelperTest < ActiveSupport::TestCase
  include SlaComplianceHelper

  test "formats dashboard durations with scan-friendly precision bands" do
    expectations = {
      1 => '1s',
      32.minutes => '32m',
      (5.hours + 32.minutes) => '5h 32m',
      (23.hours + 59.minutes) => '23h 59m',
      (1.day + 5.hours + 32.minutes) => '1d 5h',
      (5.days + 7.hours) => '5d 7h',
      (9.days + 4.hours) => '1w 2d',
      18.days => '2w 4d',
      45.days => '45d',
      (299.days + 3.hours + 34.minutes) => '299d'
    }

    expectations.each do |seconds, display|
      assert_equal display, format_sla_duration(seconds), "expected #{seconds} seconds to display as #{display}"
    end
  end

  test "omits zero-value trailing units at each boundary" do
    assert_equal '1m', format_sla_duration(1.minute)
    assert_equal '1h', format_sla_duration(1.hour)
    assert_equal '1d', format_sla_duration(1.day)
    assert_equal '1w', format_sla_duration(1.week)
    assert_equal '30d', format_sla_duration(30.days)
  end

  test "keeps blank durations blank and zero as zero seconds" do
    assert_equal '', format_sla_duration(nil)
    assert_equal '', format_sla_duration('')
    assert_equal '0s', format_sla_duration(0)
  end

  test "rounds SLA percentages to whole numbers" do
    assert_equal 100, sla_percentage(4, 4)
    assert_equal 80, sla_percentage(4, 5)
    assert_equal 67, sla_percentage(2, 3)
    assert_equal 33, sla_percentage(1, 3)
    assert_equal 0, sla_percentage(0, 0)
  end
end
