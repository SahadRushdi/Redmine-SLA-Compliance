# frozen_string_literal: true

require_relative '../../test_helper'

# Phase 2 · Step 2.6 — Result classification.
#
# Done when: "Tests cover met (open + resolved), breached, and both No-SLA sub-cases." Also
# exercises the at-risk flag, pause subtraction, reopen clock-restart, and business-hours mode.
# Config is injected via lightweight duck-typed stubs so nothing hits the DB.
class Sla::ResultClassifierTest < ActiveSupport::TestCase
  Event    = Sla::TimelineBuilder::Event
  Timeline = Sla::TimelineBuilder::Timeline
  Calendar = Struct.new(:working_days, :work_start_time, :work_end_time, :holidays,
                        keyword_init: true)

  Policy = Struct.new(:business_hours, :business_calendar, :first_response_rule,
                      :at_risk_threshold, :pause_enabled, keyword_init: true) do
    def business_hours?
      business_hours
    end
  end

  Definition = Struct.new(:response_seconds, :workaround_seconds, :resolution_seconds,
                          :response_best_effort, :workaround_best_effort, :resolution_best_effort,
                          keyword_init: true) do
    def any_target?
      [response_seconds, workaround_seconds, resolution_seconds,
       response_best_effort, workaround_best_effort, resolution_best_effort].any?
    end

    def response_best_effort?
      !!response_best_effort
    end

    def workaround_best_effort?
      !!workaround_best_effort
    end

    def resolution_best_effort?
      !!resolution_best_effort
    end
  end

  OPEN     = 1
  WORK     = 2
  RESOLVED = 3
  DONE     = 5 # a neutral status in no role
  PAUSED   = 9

  ROLES = { created: [OPEN], work_started: [WORK], resolved: [RESOLVED], pause: [PAUSED] }.freeze

  setup do
    @base   = ActiveSupport::TimeZone['UTC'].local(2026, 6, 1, 9, 0, 0)
    @policy = Policy.new(business_hours: false, business_calendar: nil,
                         first_response_rule: 'either', at_risk_threshold: 80, pause_enabled: true)
  end

  def at(hours)
    @base + hours * 3600
  end

  def timeline(changes = [], comments: [], initial: OPEN)
    events = [Event.new(type: :created, at: @base, to_status_id: initial)]
    changes.each do |from, to, at|
      events << Event.new(type: :status_change, at: at, from_status_id: from, to_status_id: to)
    end
    comments.each do |at, private_note|
      events << Event.new(type: :comment, at: at, private_note: private_note)
    end
    Timeline.new(events.sort_by(&:at))
  end

  def classify(tl, definition:, now:, policy: @policy, tracker_configured: true,
               status_roles: ROLES, current_status_id: nil, fallback_resolved_at: nil)
    Sla::ResultClassifier.new(
      timeline: tl, policy: policy, definition: definition,
      tracker_configured: tracker_configured, status_roles: status_roles,
      current_status_id: current_status_id, fallback_resolved_at: fallback_resolved_at, now: now
    ).classify
  end

  # --- No-SLA sub-cases -----------------------------------------------------------------

  test "no policy -> no_sla / not_configured" do
    r = classify(timeline, definition: Definition.new(response_seconds: 3600),
                           policy: nil, now: at(1))
    assert_equal 'no_sla', r.primary_state
    assert_equal 'not_configured', r.no_sla_reason
    assert_nil r.resolved_at, 'still open: nothing has resolved it'
  end

  test "tracker not under SLA -> no_sla / not_configured" do
    r = classify(timeline, definition: nil, tracker_configured: false, now: at(1))
    assert_equal 'no_sla', r.primary_state
    assert_equal 'not_configured', r.no_sla_reason
  end

  test "no definition for this priority -> no_sla / not_tracked" do
    r = classify(timeline, definition: nil, now: at(1))
    assert_equal 'no_sla', r.primary_state
    assert_equal 'not_tracked', r.no_sla_reason
  end

  test "definition with no targets set -> no_sla / not_tracked" do
    r = classify(timeline, definition: Definition.new, now: at(1))
    assert_equal 'not_tracked', r.no_sla_reason
  end

  # --- met ------------------------------------------------------------------------------

  test "open ticket within target is met, not at risk, with a projected breach_at" do
    d = Definition.new(response_seconds: 3600)
    now = @base + 1800 # 50% elapsed, no response yet
    r = classify(timeline, definition: d, now: now)
    assert_equal 'met', r.primary_state
    assert_equal 1800, r.response_seconds
    refute r.at_risk
    assert_equal now + 1800, r.breach_at
    assert_nil r.deviation_seconds
    assert_nil r.resolved_at, 'still open — no resolution has happened yet'
  end

  test "resolved within target is met with no breach_at" do
    d = Definition.new(response_seconds: 3600, resolution_seconds: 7200)
    tl = timeline([[OPEN, RESOLVED, at(1)]], comments: [[@base + 1800, false]])
    r = classify(tl, definition: d, now: at(5))
    assert_equal 'met', r.primary_state
    assert_equal 1800, r.response_seconds   # first (public) comment
    assert_equal 3600, r.resolution_seconds # net(base .. base+1h)
    refute r.at_risk
    assert_nil r.breach_at
    assert_equal at(1), r.resolved_at
  end

  # --- at-risk flag ---------------------------------------------------------------------

  test "open ticket past the at-risk threshold is met AND flagged at risk" do
    d = Definition.new(response_seconds: 3600)
    now = @base + 3000 # 83% > 80%, still < target
    r = classify(timeline, definition: d, now: now)
    assert_equal 'met', r.primary_state
    assert r.at_risk
    assert_equal now + 600, r.breach_at
  end

  # --- breached -------------------------------------------------------------------------

  test "open ticket past target is breached with deviation" do
    d = Definition.new(response_seconds: 3600)
    now = @base + 7200 # 2h, no response
    r = classify(timeline, definition: d, now: now)
    assert_equal 'breached', r.primary_state
    assert_equal 3600, r.deviation_seconds
    refute r.at_risk
    assert_nil r.breach_at
  end

  test "resolved after target is breached with deviation" do
    d = Definition.new(resolution_seconds: 3600)
    tl = timeline([[OPEN, RESOLVED, at(2)]]) # resolved at base+2h
    r = classify(tl, definition: d, now: at(3))
    assert_equal 'breached', r.primary_state
    assert_equal 7200, r.resolution_seconds
    assert_equal 3600, r.deviation_seconds
    assert_equal at(2), r.resolved_at
  end

  # --- Best Effort (B4: a target with no numeric deadline) ------------------------------

  test "a definition with only Best Effort set (no numeric targets) is tracked, not not_tracked" do
    r = classify(timeline, definition: Definition.new(resolution_best_effort: true), now: at(1))
    refute_equal 'not_tracked', r.no_sla_reason
    assert_equal 'met', r.primary_state
  end

  test "a Best Effort target is never breached, no matter how long it's open" do
    d = Definition.new(resolution_best_effort: true)
    now = @base + 5000.hours # absurdly overdue by any numeric standard
    r = classify(timeline, definition: d, now: now)
    assert_equal 'met', r.primary_state
    assert_nil r.deviation_seconds
    assert_equal (5000 * 3600), r.resolution_seconds, 'elapsed time is still tracked and reported'
  end

  test "a Best Effort target is never flagged at risk" do
    d = Definition.new(resolution_best_effort: true)
    # Same instant a numeric target would be well past its at-risk threshold.
    now = @base + 5000.hours
    r = classify(timeline, definition: d, now: now)
    refute r.at_risk
    assert_nil r.breach_at
  end

  test "a Best Effort target resolved late is still met, with no deviation" do
    d = Definition.new(resolution_best_effort: true)
    tl = timeline([[OPEN, RESOLVED, at(500)]])
    r = classify(tl, definition: d, now: at(501))
    assert_equal 'met', r.primary_state
    assert_nil r.deviation_seconds
  end

  test "one Best Effort milestone doesn't shield a numeric milestone on the same ticket from breaching" do
    d = Definition.new(response_seconds: 3600, resolution_best_effort: true)
    now = @base + 7200 # 2h, no response — breaches the numeric response target
    r = classify(timeline, definition: d, now: now)
    assert_equal 'breached', r.primary_state
    assert_equal 3600, r.deviation_seconds
  end

  # --- pause integration ----------------------------------------------------------------

  test "paused time is subtracted, keeping a would-be breach within target" do
    # Use the first_comment rule with no comment so the response milestone stays pending and
    # its elapsed reflects the pause subtraction (under 'either' the pause transition itself
    # would count as the first response).
    policy = Policy.new(business_hours: false, business_calendar: nil,
                        first_response_rule: 'first_comment', at_risk_threshold: 80,
                        pause_enabled: true)
    d = Definition.new(response_seconds: 3600)
    # Paused status 9 from base+1000 to base+5000 (4000s), then a neutral status.
    tl = timeline([[OPEN, PAUSED, @base + 1000], [PAUSED, DONE, @base + 5000]])
    now = @base + 7200 # gross 2h, minus 4000s pause = 3200s net
    r = classify(tl, definition: d, policy: policy, now: now)
    assert_equal 'met', r.primary_state
    assert_equal 3200, r.response_seconds
  end

  # --- reopen restarts the clock --------------------------------------------------------

  test "a reopened ticket measures the response from the reopen, not the original creation" do
    d = Definition.new(response_seconds: 3600)
    # Resolved at +2h, reopened (back to OPEN, a created-role status) at +5h,
    # first response 30m after the reopen.
    tl = timeline([[OPEN, RESOLVED, at(2)], [RESOLVED, OPEN, at(5)]],
                  comments: [[at(5) + 1800, false]])
    r = classify(tl, definition: d, now: at(5) + 2000)
    assert_equal 'met', r.primary_state
    assert_equal 1800, r.response_seconds # measured from the reopen at +5h
    assert_nil r.breach_at                # response already achieved; nothing pending
    refute r.at_risk
  end

  test "resolved, reopened, and resolved again reports resolved_at from the second resolution" do
    d = Definition.new(resolution_seconds: 3600)
    tl = timeline([[OPEN, RESOLVED, at(1)], [RESOLVED, OPEN, at(2)], [OPEN, RESOLVED, at(4)]])
    r = classify(tl, definition: d, now: at(5))
    assert_equal at(4), r.resolved_at, "closed_at's clock_start filter already excludes the " \
                                       'first (pre-reopen) resolution for free'
  end

  # --- business-hours mode --------------------------------------------------------------

  test "business-hours mode measures elapsed and projects breach_at in working time" do
    Time.use_zone('UTC') do
      zone = Time.zone
      base = zone.local(2026, 6, 3, 9, 0) # Wednesday 09:00
      policy = Policy.new(
        business_hours: true,
        business_calendar: Calendar.new(working_days: [1, 2, 3, 4, 5], work_start_time: '09:00',
                                        work_end_time: '17:00', holidays: []),
        first_response_rule: 'either', at_risk_threshold: 80, pause_enabled: true
      )
      tl = Timeline.new([Event.new(type: :created, at: base, to_status_id: OPEN)])
      d  = Definition.new(response_seconds: 14_400) # 4 business hours

      r = Sla::ResultClassifier.new(
        timeline: tl, policy: policy, definition: d, tracker_configured: true,
        status_roles: ROLES, now: zone.local(2026, 6, 3, 11, 0)
      ).classify

      assert_equal 'met', r.primary_state
      assert_equal 7200, r.response_seconds # 2 working hours
      refute r.at_risk                      # 50%
      assert_equal zone.local(2026, 6, 3, 13, 0), r.breach_at # +2 working hours
    end
  end

  test "business-hours mode: past the at-risk threshold is met AND flagged at risk" do
    Time.use_zone('UTC') do
      zone = Time.zone
      base = zone.local(2026, 6, 3, 9, 0) # Wednesday 09:00
      policy = Policy.new(
        business_hours: true,
        business_calendar: Calendar.new(working_days: [1, 2, 3, 4, 5], work_start_time: '09:00',
                                        work_end_time: '17:00', holidays: []),
        first_response_rule: 'either', at_risk_threshold: 80, pause_enabled: true
      )
      tl = Timeline.new([Event.new(type: :created, at: base, to_status_id: OPEN)])
      d  = Definition.new(response_seconds: 14_400) # 4 business hours

      # +3h20m working time = 83% of the 4h target, still short of it.
      now = zone.local(2026, 6, 3, 12, 20)
      r = Sla::ResultClassifier.new(
        timeline: tl, policy: policy, definition: d, tracker_configured: true,
        status_roles: ROLES, now: now
      ).classify

      assert_equal 'met', r.primary_state
      assert r.at_risk
      assert_equal zone.local(2026, 6, 3, 13, 0), r.breach_at # +40 working minutes
    end
  end

  test "business-hours mode: past target is breached with deviation" do
    Time.use_zone('UTC') do
      zone = Time.zone
      base = zone.local(2026, 6, 3, 9, 0) # Wednesday 09:00
      policy = Policy.new(
        business_hours: true,
        business_calendar: Calendar.new(working_days: [1, 2, 3, 4, 5], work_start_time: '09:00',
                                        work_end_time: '17:00', holidays: []),
        first_response_rule: 'either', at_risk_threshold: 80, pause_enabled: true
      )
      tl = Timeline.new([Event.new(type: :created, at: base, to_status_id: OPEN)])
      d  = Definition.new(response_seconds: 14_400) # 4 business hours

      # Thu 10:00: Wed 09:00-17:00 (8h) + Thu 09:00-10:00 (1h) = 9h working, well past the 4h target.
      now = zone.local(2026, 6, 4, 10, 0)
      r = Sla::ResultClassifier.new(
        timeline: tl, policy: policy, definition: d, tracker_configured: true,
        status_roles: ROLES, now: now
      ).classify

      assert_equal 'breached', r.primary_state
      refute r.at_risk
      assert_nil r.breach_at
      assert_equal (32_400 - 14_400), r.deviation_seconds
    end
  end

  # --- resolved_at: the open/resolved ladder --------------------------------------------
  # `resolved_at` is what the dashboard's "open" filter reads (open = resolved_at IS NULL), so
  # every rung of Sla::ResultClassifier#closed_at has to be exercised: a ticket stuck at nil sits
  # in the open population for life.

  test "rung 1: a transition into a resolved-role status is the resolution instant" do
    d  = Definition.new(resolution_seconds: 36_000)
    tl = timeline([[OPEN, RESOLVED, at(2)]])

    r = classify(tl, definition: d, now: at(50))

    assert_equal at(2), r.resolved_at
    assert_equal 'met', r.primary_state
  end

  test "rung 2: sitting in a resolved status with no recorded transition falls back to closed_on" do
    d  = Definition.new(resolution_seconds: 36_000)
    tl = timeline([], initial: RESOLVED) # created directly as Resolved — no transition to find

    r = classify(tl, definition: d, now: at(50),
                 current_status_id: RESOLVED, fallback_resolved_at: at(3))

    assert_equal at(3), r.resolved_at
  end

  test "rung 2 with no closed_on: uses the last recorded activity, not `now`" do
    d  = Definition.new(resolution_seconds: 36_000)
    # A "Resolved" status Redmine does not treat as closed leaves closed_on nil. Anchoring on the
    # last event keeps the value stable across sweeps; `now` would drift on every run.
    tl = timeline([], comments: [[at(4), false]], initial: RESOLVED)

    r = classify(tl, definition: d, now: at(50), current_status_id: RESOLVED)

    assert_equal at(4), r.resolved_at
  end

  test "rung 3: with no resolved statuses configured at all, Redmine's closed_on decides" do
    r = classify(timeline, definition: Definition.new(response_seconds: 3600), policy: nil,
                 status_roles: {}, now: at(5), fallback_resolved_at: at(2))

    assert_equal 'not_configured', r.no_sla_reason
    assert_equal at(2), r.resolved_at, 'a No-SLA ticket must still be able to leave the open population'
  end

  test "a ticket in a non-resolved status stays open on every rung" do
    d = Definition.new(resolution_seconds: 36_000)

    r = classify(timeline([[OPEN, WORK, at(1)]]), definition: d, now: at(5),
                 current_status_id: WORK, fallback_resolved_at: nil)

    assert_nil r.resolved_at
  end

  test "a no_sla / not_tracked ticket reports resolved_at like any other" do
    tl = timeline([[OPEN, RESOLVED, at(6)]])

    r = classify(tl, definition: nil, now: at(50))

    assert_equal 'not_tracked', r.no_sla_reason
    assert_equal at(6), r.resolved_at
    assert_nil r.cycle_started_at, 'no_sla never reaches the at-risk path that consumes it'
  end

  test "a reopened ticket is open again: the resolution instant is cleared" do
    d = Definition.new(resolution_seconds: 36_000)
    # Resolved at +2h, reopened at +4h. clock_start moves to the reopen, and #first_transition_into
    # only counts transitions after it — so there is no resolution in the current cycle.
    tl = timeline([[OPEN, RESOLVED, at(2)], [RESOLVED, OPEN, at(4)]])

    r = classify(tl, definition: d, now: at(5), current_status_id: OPEN)

    assert_nil r.resolved_at
    assert_equal at(4), r.cycle_started_at
  end
end
