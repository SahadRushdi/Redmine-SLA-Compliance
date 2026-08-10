require_relative '../../test_helper'

class SlaDirectDurationTest < ActiveSupport::TestCase
  test 'hours and days become wall-clock seconds' do
    assert_equal({ seconds: 9_000, best_effort: false, unit: 'hours' },
                 Sla::DirectDuration.parse(mode: 'duration', value: '2.5', unit: 'hours'))
    assert_equal({ seconds: 259_200, best_effort: false, unit: 'days' },
                 Sla::DirectDuration.parse(mode: 'duration', value: '3', unit: 'days'))
  end

  test 'best effort and unset have no numeric deadline' do
    assert_equal({ seconds: nil, best_effort: true },
                 Sla::DirectDuration.parse(mode: 'best_effort'))
    assert_equal({ seconds: nil, best_effort: false },
                 Sla::DirectDuration.parse(mode: 'unset'))
  end

  test 'invalid, zero, negative and excessive durations are rejected' do
    ['', '0', '-1', 'nope'].each do |value|
      assert_raises(Sla::DirectDuration::InvalidDuration) do
        Sla::DirectDuration.parse(mode: 'duration', value: value, unit: 'hours')
      end
    end
    assert_raises(Sla::DirectDuration::InvalidDuration) do
      Sla::DirectDuration.parse(mode: 'duration', value: '999999999', unit: 'days')
    end
  end

  test 'labels use days only for exact whole days' do
    assert_equal '72 Hours', Sla::DirectDuration.label(seconds: 259_200, best_effort: false,
                                                       unit: 'hours')
    assert_equal '2.5 Hours', Sla::DirectDuration.label(seconds: 9_000, best_effort: false)
    assert_equal 'Best Effort', Sla::DirectDuration.label(seconds: nil, best_effort: true)
  end
end
