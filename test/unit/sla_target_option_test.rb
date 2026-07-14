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
end
