require_relative '../test_helper'

# The Priority Targets table colours each priority with a severity pill. Global Rule 1 forbids
# hard-coding domain values, so the colour must come from the priority's RANK among the active
# priorities and never from its name — a site that renames, reorders, adds or removes priorities
# has to keep getting a sensible low→high ramp with no code change.
class SlaPriorityBadgeTest < ActionView::TestCase
  tests SlaPoliciesHelper

  fixtures :enumerations

  def badges_in_rank_order
    IssuePriority.active.map { |priority| sla_priority_badge_classes(priority) }
  end

  test "the lowest priority takes the coolest stop and the highest the hottest" do
    badges = badges_in_rank_order
    assert_operator badges.size, :>=, 2, 'fixtures must supply at least two active priorities'
    assert_equal SlaPoliciesHelper::PRIORITY_BADGE_RAMP.first, badges.first
    assert_equal SlaPoliciesHelper::PRIORITY_BADGE_RAMP.last, badges.last
  end

  test "the ramp never runs backwards as priority rises" do
    stops = badges_in_rank_order.map { |badge| SlaPoliciesHelper::PRIORITY_BADGE_RAMP.index(badge) }
    assert_nil stops.index(nil), 'every badge must be one of the declared ramp stops'
    assert_equal stops.sort, stops, "rank order #{stops.inspect} must map to non-decreasing colours"
  end

  # Renaming a priority is a pure relabelling: nothing about severity changed, so nothing about
  # the colour may change either. This is the assertion that fails the moment someone reaches for
  # a name-keyed lookup table.
  test "renaming every priority changes no colour" do
    before = badges_in_rank_order
    IssuePriority.active.each_with_index do |priority, index|
      priority.update_columns(name: "Renamed #{index}")
    end
    assert_equal before, badges_in_rank_order
  end

  test "a single active priority still gets a valid stop rather than dividing by zero" do
    keep = IssuePriority.active.first
    IssuePriority.active.where.not(id: keep.id).update_all(active: false)
    @sla_active_priority_ids = nil

    assert_includes SlaPoliciesHelper::PRIORITY_BADGE_RAMP, sla_priority_badge_classes(keep)
  end

  test "a priority outside the active list falls back instead of raising" do
    inactive = IssuePriority.active.last
    inactive.update_columns(active: false)
    @sla_active_priority_ids = nil

    assert_includes SlaPoliciesHelper::PRIORITY_BADGE_RAMP, sla_priority_badge_classes(inactive)
  end
end
