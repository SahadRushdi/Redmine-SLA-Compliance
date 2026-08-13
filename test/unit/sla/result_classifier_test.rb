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

  # Duck-typed stand-in for SlaDefinition, built from the model's own target list so a new target
  # (Update Frequency) can't be measured by the classifier without this stub answering for it.
  Definition = Struct.new(*SlaDefinition::TARGET_TYPES.flat_map { |type|
                            [:"#{type}_seconds", :"#{type}_best_effort"]
                          }, keyword_init: true) do
    def any_target?
      to_h.values.any?
    end

    SlaDefinition::TARGET_TYPES.each do |type|
      define_method(:"#{type}_best_effort?") { !!public_send(:"#{type}_best_effort") }
    end
  end

  OPEN     = 1
  WORK     = 2
  RESOLVED = 3
  CLOSED   = 4 # a SECOND resolved-role status — the "Waiting on Client then Closed" shape
  DONE     = 5 # a neutral status in no role
  PAUSED   = 9

  ROLES = { created: [OPEN], work_started: [WORK], resolved: [RESOLVED, CLOSED],
            pause: [PAUSED] }.freeze

  HUMAN     = 7 # a person's user id
  ANONYMOUS = 8 # Redmine's anonymous user (Sla::PolicyContext#non_human_author_ids)

  setup do
    @base   = ActiveSupport::TimeZone['UTC'].local(2026, 6, 1, 9, 0, 0)
    @policy = Policy.new(business_hours: false, business_calendar: nil,
                         first_response_rule: 'either', at_risk_threshold: 80, pause_enabled: true)
  end

  def at(hours)
    @base + hours * 3600
  end

  # Comment entries are [at, private_note, user_id]; the author defaults to a human, since that is
  # what a real journal always has and what the Update Frequency target requires (ANONYMOUS is
  # passed explicitly by the tests that need a non-human author).
  def timeline(changes = [], comments: [], initial: OPEN)
    events = [Event.new(type: :created, at: @base, to_status_id: initial)]
    changes.each do |from, to, at|
      events << Event.new(type: :status_change, at: at, from_status_id: from, to_status_id: to)
    end
    comments.each do |at, private_note, user_id|
      events << Event.new(type: :comment, at: at, private_note: private_note,
                          user_id: user_id || HUMAN)
    end
    Timeline.new(events.sort_by(&:at))
  end

  def classify(tl, definition:, now:, policy: @policy, tracker_configured: true,
               status_roles: ROLES, current_status_id: nil, fallback_resolved_at: nil,
               non_human_author_ids: [ANONYMOUS])
    Sla::ResultClassifier.new(
      timeline: tl, policy: policy, definition: definition,
      tracker_configured: tracker_configured, status_roles: status_roles,
      current_status_id: current_status_id, fallback_resolved_at: fallback_resolved_at,
      non_human_author_ids: non_human_author_ids, now: now
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

  # --- Step 6A.6: resolved means CURRENTLY resolved -------------------------------------
  #
  # `closed_at` used to take the FIRST transition into a resolved-role status and treat it as
  # final. "Waiting on Client" is a resolved-role status on a typical policy, so a ticket that
  # went New -> Waiting on Client -> In progress was recorded as resolved two hours after
  # creation and stayed that way while it was actively being worked: gone from every open-ticket
  # figure, resolution time understated, and counted in the SLA Met percentage for a period it
  # had not resolved in.

  test "a ticket that came back OUT of a resolved status is open again, not resolved forever" do
    d = Definition.new(resolution_seconds: 36_000)
    # The exact defect shape: resolved-role status entered at +2h, LEFT at +26h for a work status
    # that is not a `created`-role status, so nothing restarts the clock and hides the bug.
    tl = timeline([[OPEN, RESOLVED, at(2)], [RESOLVED, WORK, at(26)]])

    r = classify(tl, definition: d, now: at(240), current_status_id: WORK)

    assert_nil r.resolved_at, 'it is sitting in a work status — it has not resolved'
  end

  test "returning via a created-role status also stays open (the path that used to mask this)" do
    d  = Definition.new(resolution_seconds: 36_000)
    tl = timeline([[OPEN, RESOLVED, at(2)], [RESOLVED, OPEN, at(3)], [OPEN, WORK, at(4)]])

    r = classify(tl, definition: d, now: at(10), current_status_id: WORK)

    assert_nil r.resolved_at
  end

  test "moving between two resolved statuses keeps the instant it ENTERED the resolved set" do
    d = Definition.new(resolution_seconds: 36_000)
    # Waiting on Client at +2h, then formally Closed three days later, never leaving the set.
    # The SLA clock stopped at +2h; the later hop inside the set must not advance it.
    tl = timeline([[OPEN, RESOLVED, at(2)], [RESOLVED, CLOSED, at(74)]])

    r = classify(tl, definition: d, now: at(100), current_status_id: CLOSED)

    assert_equal at(2), r.resolved_at
    assert_equal 7200, r.resolution_seconds
  end

  test "bounced back out and resolved again reports the SECOND resolution" do
    d = Definition.new(resolution_seconds: 36_000) # 10h
    tl = timeline([[OPEN, RESOLVED, at(2)], [RESOLVED, WORK, at(5)], [WORK, CLOSED, at(50)]])

    r = classify(tl, definition: d, now: at(60), current_status_id: CLOSED)

    assert_equal at(50), r.resolved_at, 'the clock re-armed when it left the resolved set'
    assert_equal 180_000, r.resolution_seconds, '50h, not the 2h of the first resolution'
    assert_equal 'breached', r.primary_state
  end

  test "while bounced back out, the Resolution target can breach again" do
    d = Definition.new(resolution_seconds: 36_000) # 10h
    tl = timeline([[OPEN, RESOLVED, at(2)], [RESOLVED, WORK, at(3)]])

    r = classify(tl, definition: d, now: at(40), current_status_id: WORK)

    assert_nil r.resolved_at
    assert_equal 'breached', r.primary_state,
                 'the milestone re-armed — it must not stay satisfied by the first resolution'
    assert_equal 144_000 - 36_000, r.deviation_seconds
  end

  test "the issue's live status wins when it disagrees with the journal history" do
    d = Definition.new(resolution_seconds: 36_000)
    # Timeline's last recorded transition lands in a resolved status, but the issue is really in a
    # work status (a transition Redmine never journalled). The live status is the authority on
    # WHERE the ticket is; the timeline only says when it got there.
    tl = timeline([[OPEN, RESOLVED, at(2)]])

    r = classify(tl, definition: d, now: at(40), current_status_id: WORK)

    assert_nil r.resolved_at
  end

  # --- Update Frequency: a fourth target of equal standing ------------------------------
  #
  # The evaluator's own gap/qualifying-update rules are covered in
  # test/unit/sla/update_frequency_evaluator_test.rb. What matters HERE is that the classifier
  # treats it exactly like the other three: same skip rule, same breach consequence, same at-risk
  # threshold — plus the one thing that is genuinely different, the at-risk check reading the gap
  # running now rather than the longest gap ever seen.

  FOUR_HOURS = 4 * 3600

  test "update frequency not configured -> not evaluated, however quiet the ticket goes" do
    d = Definition.new(resolution_seconds: 360_000) # only Resolution is tracked
    r = classify(timeline, definition: d, now: at(50)) # 50h of total silence

    assert_equal 'met', r.primary_state
    assert_nil r.update_frequency_seconds, 'a nil target means the milestone is skipped entirely'
    assert_nil r.deviation_seconds
  end

  test "no qualifying update since creation past the target -> breached, like a late resolution" do
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)
    r = classify(timeline, definition: d, now: at(5))

    assert_equal 'breached', r.primary_state
    assert_equal 5 * 3600, r.update_frequency_seconds, 'the largest quiet gap so far'
    assert_equal 3600, r.deviation_seconds, 'one hour past the cadence'
    assert_equal at(4), r.deviation_at, 'the current silence keeps growing from its target deadline'
    refute r.at_risk, 'a breached ticket is past at-risk, exactly as for the other targets'
    assert_nil r.breach_at
  end

  test "a recovered historical cadence breach keeps its deviation but does not keep growing" do
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)
    tl = timeline(comments: [[at(5), false]]) # breached by 1h, then activity resets the live gap

    r = classify(tl, definition: d, now: at(6))

    assert_equal 'breached', r.primary_state
    assert_equal 3600, r.deviation_seconds
    assert_nil r.deviation_at, 'the current one-hour gap is not overdue'
  end

  test "qualifying updates spaced under the target -> met" do
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)
    tl = timeline(comments: [[at(2), false], [at(5), false]])

    r = classify(tl, definition: d, now: at(6))

    assert_equal 'met', r.primary_state
    assert_equal 3 * 3600, r.update_frequency_seconds # the +2h -> +5h gap, the largest
    assert_nil r.deviation_seconds
  end

  test "a comment from a non-human author does not reset the cadence" do
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)
    tl = timeline(comments: [[at(2), false, ANONYMOUS]])

    r = classify(tl, definition: d, now: at(5))

    assert_equal 'breached', r.primary_state
    assert_equal 5 * 3600, r.update_frequency_seconds, 'anonymous is not a person reporting work'
  end

  test "approaching the update frequency target flags at risk with a projected breach_at" do
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)
    now = @base + 12_600 # 87.5% of the cadence used, threshold is 80%

    r = classify(timeline, definition: d, now: now)

    assert_equal 'met', r.primary_state
    assert r.at_risk, 'same warn-before-breach treatment as Response/Workaround/Resolution'
    assert_equal now + 1800, r.breach_at
  end

  test "a long silence that has since been broken is not at risk" do
    # 3h54m of silence — 97% of the cadence — but a human commented a moment ago, so the ticket is
    # nowhere near breaching. The breach judgement still uses the largest gap; only the at-risk
    # check switches to the gap running now.
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)
    tl = timeline(comments: [[@base + 14_040, false]])

    r = classify(tl, definition: d, now: @base + 14_400)

    assert_equal 'met', r.primary_state
    assert_equal 14_040, r.update_frequency_seconds
    refute r.at_risk, 'the current gap is 6 minutes, not the 3h54m it recovered from'
  end

  # --- the at-risk dedup key: which target, and which episode --------------------------------

  test "at-risk reports the target and, for a one-shot milestone, the clock start as its episode" do
    d = Definition.new(response_seconds: 3600)
    r = classify(timeline, definition: d, now: @base + 3000) # 83% of the response target

    assert r.at_risk
    assert_equal 'response', r.at_risk_target
    assert_equal @base, r.at_risk_since, 'a one-shot target has one at-risk window per cycle'
    assert_equal r.cycle_started_at, r.at_risk_since
  end

  test "at-risk on the cadence reports the RUNNING silence as its episode, not the cycle" do
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)
    # Quiet 3h (inside the cadence), a comment at +3h, then quiet again — this second silence is
    # the one running now, and it is what the warning is about.
    tl = timeline(comments: [[at(3), false]])

    r = classify(tl, definition: d, now: at(6.6)) # 3h36m of the 4h cadence used = 90%

    assert r.at_risk
    assert_equal 'update_frequency', r.at_risk_target
    assert_equal at(3), r.at_risk_since, 'the episode is this silence, keyed on when it began'
    assert_equal @base, r.cycle_started_at, 'while the measurement cycle is unchanged'
  end

  test "a ticket that is not at risk reports no target or episode" do
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)
    r = classify(timeline, definition: d, now: at(1))

    refute r.at_risk
    assert_nil r.at_risk_target
    assert_nil r.at_risk_since
  end

  test "a breached ticket reports no at-risk target" do
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)
    r = classify(timeline, definition: d, now: at(5))

    assert_equal 'breached', r.primary_state
    assert_nil r.at_risk_target
    assert_nil r.at_risk_since
  end

  # --- the non-human-author lookup is deferred until a cadence target needs it ---------------

  test "the non-human-author lookup is never performed when no cadence target is configured" do
    calls = 0
    resolver = -> { calls += 1; [ANONYMOUS] }
    d = Definition.new(response_seconds: 3600, resolution_seconds: 36_000)

    classify(timeline(comments: [[at(0.5), false]]), definition: d, now: at(1),
             non_human_author_ids: resolver)

    assert_equal 0, calls, 'an issue with no Update Frequency target must not pay the query'
  end

  test "the non-human-author lookup is performed once when a cadence target is configured" do
    calls = 0
    resolver = -> { calls += 1; [ANONYMOUS] }
    d = Definition.new(update_frequency_seconds: FOUR_HOURS)

    r = classify(timeline(comments: [[at(2), false, ANONYMOUS]]), definition: d, now: at(5),
                 non_human_author_ids: resolver)

    assert_equal 1, calls
    assert_equal 'breached', r.primary_state, 'and the resolved list is actually applied'
  end

  test "a Best Effort update frequency never breaches but still reports its largest gap" do
    d = Definition.new(update_frequency_best_effort: true)

    r = classify(timeline, definition: d, now: at(100))

    assert_equal 'met', r.primary_state
    assert_equal 100 * 3600, r.update_frequency_seconds
    refute r.at_risk
    assert_nil r.deviation_seconds
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
