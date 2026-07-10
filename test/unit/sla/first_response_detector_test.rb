# frozen_string_literal: true

require_relative '../../test_helper'

# Phase 2 · Step 2.5 — First-response detection.
#
# Done when: "Tests cover all three rules (comment / status change / either) and private-note
# exclusion." Timelines are built from the real Sla::TimelineBuilder value objects with
# hand-crafted events — no DB.
class Sla::FirstResponseDetectorTest < ActiveSupport::TestCase
  Event    = Sla::TimelineBuilder::Event
  Timeline = Sla::TimelineBuilder::Timeline

  OPEN     = 1
  ASSIGNED = 2

  setup do
    @zone = ActiveSupport::TimeZone['UTC']
    @base = @zone.local(2026, 6, 1, 9, 0, 0)
  end

  def at(hours)
    @base + hours * 3600
  end

  def timeline(*events)
    created = Event.new(type: :created, at: @base, to_status_id: OPEN)
    Timeline.new(([created] + events).sort_by(&:at))
  end

  def comment(at, private: false)
    Event.new(type: :comment, at: at, private_note: private)
  end

  def status_change(at, from:, to:)
    Event.new(type: :status_change, at: at, from_status_id: from, to_status_id: to)
  end

  def detect(tl, rule, **opts)
    Sla::FirstResponseDetector.new(tl, rule: rule).detect(**opts)
  end

  # --- first_comment --------------------------------------------------------------------

  test "first_comment returns the earliest public comment" do
    tl = timeline(comment(at(2)), comment(at(4)))
    assert_equal at(2), detect(tl, 'first_comment')
  end

  test "first_comment excludes private notes" do
    tl = timeline(comment(at(1), private: true), comment(at(3)))
    assert_equal at(3), detect(tl, 'first_comment')
  end

  test "first_comment is nil when only private notes exist" do
    tl = timeline(comment(at(1), private: true), comment(at(2), private: true))
    assert_nil detect(tl, 'first_comment')
  end

  test "first_comment ignores status changes" do
    tl = timeline(status_change(at(1), from: OPEN, to: ASSIGNED), comment(at(4)))
    assert_equal at(4), detect(tl, 'first_comment')
  end

  # --- first_status_change --------------------------------------------------------------

  test "first_status_change returns the earliest status transition" do
    tl = timeline(status_change(at(2), from: OPEN, to: ASSIGNED),
                  status_change(at(5), from: ASSIGNED, to: 3))
    assert_equal at(2), detect(tl, 'first_status_change')
  end

  test "first_status_change ignores comments (even public ones)" do
    tl = timeline(comment(at(1)), status_change(at(3), from: OPEN, to: ASSIGNED))
    assert_equal at(3), detect(tl, 'first_status_change')
  end

  # --- either ---------------------------------------------------------------------------

  test "either returns the comment when it precedes the status change" do
    tl = timeline(comment(at(2)), status_change(at(4), from: OPEN, to: ASSIGNED))
    assert_equal at(2), detect(tl, 'either')
  end

  test "either returns the status change when it precedes the comment" do
    tl = timeline(status_change(at(1), from: OPEN, to: ASSIGNED), comment(at(3)))
    assert_equal at(1), detect(tl, 'either')
  end

  test "either excludes private notes but still sees status changes" do
    tl = timeline(comment(at(1), private: true), status_change(at(2), from: OPEN, to: ASSIGNED))
    assert_equal at(2), detect(tl, 'either')
  end

  # --- no response / boundary -----------------------------------------------------------

  test "returns nil when there is no response" do
    assert_nil detect(timeline, 'either')
  end

  test "since restricts to responses strictly after the given instant" do
    tl = timeline(comment(at(2)), comment(at(6)))
    assert_equal at(6), detect(tl, 'first_comment', since: at(5))
  end

  test "since is exclusive so a reopen transition at the boundary is not counted" do
    # Reopen (back to OPEN) at at(5), then a genuine response at at(7).
    tl = timeline(status_change(at(5), from: 3, to: OPEN),
                  status_change(at(7), from: OPEN, to: ASSIGNED))
    assert_equal at(7), detect(tl, 'first_status_change', since: at(5))
  end

  test "unknown rule raises ArgumentError" do
    assert_raises(ArgumentError) { detect(timeline(comment(at(2))), 'bogus') }
  end
end
