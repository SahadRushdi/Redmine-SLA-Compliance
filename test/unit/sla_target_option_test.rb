# frozen_string_literal: true

require_relative '../test_helper'

# SlaTargetOption — the admin-managed duration lookup, including Best Effort and basis (B4).
class SlaTargetOptionTest < ActiveSupport::TestCase
  def valid_attrs(overrides = {})
    { target_type: 'response', code: '1h', label: '1 hour', seconds: 3600 }.merge(overrides)
  end

  test "a normal option requires a positive seconds value" do
    option = SlaTargetOption.new(valid_attrs(seconds: nil))
    refute option.valid?
    assert option.errors[:seconds].present?
  end

  test "basis defaults to calendar" do
    assert_equal 'calendar', SlaTargetOption.new(valid_attrs).basis
  end

  test "basis must be calendar or business" do
    option = SlaTargetOption.new(valid_attrs(basis: 'business'))
    assert option.valid?
    option.basis = 'bogus'
    refute option.valid?
  end

  # --- Best Effort ---------------------------------------------------------------------------

  test "a Best Effort option does not require seconds" do
    option = SlaTargetOption.new(valid_attrs(seconds: nil, best_effort: true))
    assert option.valid?
  end

  test "a Best Effort option must NOT have a seconds value" do
    option = SlaTargetOption.new(valid_attrs(seconds: 3600, best_effort: true))
    refute option.valid?
    assert option.errors[:seconds].present?
  end

  test "best_effort defaults to false" do
    refute SlaTargetOption.new(valid_attrs).best_effort?
  end

  # --- Duration entered as an amount + a unit (the form's only duration input) -----------------

  test "an amount and a unit are stored as seconds" do
    {
      %w[30 minutes] => 1_800,
      %w[4 hours]    => 14_400,
      %w[24 hours]   => 86_400,
      %w[72 hours]   => 259_200, # the longest option in the live lookup
      %w[1 days]     => 86_400,
      %w[3 days]     => 259_200  # the same target, entered the other way round
    }.each do |(amount, unit), expected|
      option = SlaTargetOption.new(valid_attrs(seconds: nil, duration_amount: amount,
                                               duration_unit: unit))
      assert option.valid?, "#{amount} #{unit} should be valid: #{option.errors.full_messages}"
      assert_equal expected, option.seconds, "#{amount} #{unit}"
    end
  end

  # The editor must open on the same reading of the number that the list column shows, or the two
  # screens disagree about one stored value.
  test "a stored duration is read back in the largest unit that divides it exactly" do
    {
      1_800   => [30, 'minutes'],
      14_400  => [4,  'hours'],
      86_400  => [1,  'days'],
      172_800 => [2,  'days'],   # displayed as "2d" in the list
      259_200 => [3,  'days'],
      18_000  => [5,  'hours'],
      5_400   => [90, 'minutes'] # 1.5h is not a whole number of hours
    }.each do |seconds, (amount, unit)|
      option = SlaTargetOption.new(valid_attrs(seconds: seconds))
      assert_equal unit, option.duration_unit, "#{seconds}s unit"
      assert_equal amount, option.duration_amount, "#{seconds}s amount"
    end
  end

  # The form is minute-resolution, so a stored value carrying stray seconds cannot round-trip.
  # Nothing in the lookup has ever held one (every option is whole hours), and the column stays
  # authoritative — this asserts the loss is a truncation, not a jump to some other duration.
  test "a duration that is not a whole minute truncates to the minute when re-entered" do
    option = SlaTargetOption.new(valid_attrs(seconds: 90))

    assert_equal 'minutes', option.duration_unit
    assert_equal 1, option.duration_amount
  end

  test "a blank duration is rejected rather than saved as zero" do
    option = SlaTargetOption.new(valid_attrs(seconds: nil, duration_amount: '',
                                             duration_unit: 'hours'))

    refute option.valid?
    assert option.errors[:seconds].present?
  end

  # Nothing on the form can post one, but an edit must refuse rather than silently pick a
  # multiplier and store a duration the admin never asked for.
  test "an unrecognised unit blanks the duration instead of guessing" do
    option = SlaTargetOption.new(valid_attrs(seconds: 14_400, duration_amount: '4',
                                             duration_unit: 'fortnights'))

    refute option.valid?
    assert option.errors[:seconds].present?
  end

  test "the duration parts are ignored for a Best Effort option" do
    option = SlaTargetOption.new(valid_attrs(seconds: nil, best_effort: true,
                                             duration_amount: '4', duration_unit: 'hours'))

    assert option.valid?, option.errors.full_messages.to_s
    assert_nil option.seconds, 'Best Effort must never carry a numeric duration'
  end

  test "seconds set directly is left alone — fixtures and older payloads still work" do
    option = SlaTargetOption.new(valid_attrs(seconds: 7_200))

    assert option.valid?
    assert_equal 7_200, option.seconds
  end

  # --- Derived code ----------------------------------------------------------------------------

  test "code is derived from the label when the form does not supply one" do
    option = SlaTargetOption.create!(valid_attrs(code: nil, label: '4 Hours'))
    assert_equal '4-hours', option.code
  end

  test "a supplied code still wins over the derived one" do
    option = SlaTargetOption.create!(valid_attrs(code: '4h', label: '4 Hours'))
    assert_equal '4h', option.code
  end

  # The uniqueness validation is still in force on a column the form no longer shows, so a create
  # must never fail because someone reused a label.
  test "a duplicate label within a target type derives a distinct code" do
    first = SlaTargetOption.create!(valid_attrs(code: nil, label: '4 Hours'))
    second = SlaTargetOption.create!(valid_attrs(code: nil, label: '4 Hours', seconds: 14_400))

    assert_equal '4-hours', first.code
    assert_equal '4-hours-2', second.code
  end

  test "the same label under a different target type keeps the plain code" do
    SlaTargetOption.create!(valid_attrs(code: nil, label: '4 Hours'))
    other = SlaTargetOption.create!(valid_attrs(code: nil, label: '4 Hours',
                                                target_type: 'resolution'))

    assert_equal '4-hours', other.code, 'codes are unique per target type, not globally'
  end

  # parameterize strips anything non-Latin to an empty string, which would fail the presence
  # validation on a field with no way to fix it from the form.
  test "a label that parameterizes to nothing still yields a code" do
    option = SlaTargetOption.create!(valid_attrs(code: nil, label: '４時間'))
    assert option.code.present?
  end

  test "editing an option does not collide its derived code with itself" do
    option = SlaTargetOption.create!(valid_attrs(code: nil, label: '4 Hours'))

    assert option.update(label: '4 Hours (calendar)')
    assert_equal '4-hours', option.code, 'an existing code is kept, not re-derived'
  end
end
