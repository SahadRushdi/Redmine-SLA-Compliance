# frozen_string_literal: true

require_relative '../../test_helper'

# Update Frequency — the recurring cadence target (Sla::UpdateFrequencyEvaluator).
#
# Built over hand-crafted journal histories on a fresh issue, because the rule this target lives or
# dies by is a property of real Redmine journals: `notes` and `journal_details` are separate things
# on the SAME object, and only the first makes a journal a status update. Going through
# Sla::TimelineBuilder (rather than hand-building timeline events) is what proves a details-only
# journal — a tracker switch, a % Done bump — never reaches the evaluator at all.
#
# All records are created inside Redmine's transactional tests and rolled back; nothing persists.
# Core fixtures: statuses New=1, Assigned=2, Resolved=3, Feedback=4.
class Sla::UpdateFrequencyEvaluatorTest < ActiveSupport::TestCase
  fixtures :projects, :users, :issues, :issue_statuses, :trackers, :enumerations,
           :roles, :members, :member_roles

  NEW      = 1
  RESOLVED = 3
  WAITING  = 4 # stands in for a "Waiting on Client"-style configured pause status

  FOUR_HOURS = 4 * 3600

  setup do
    User.current = User.find(2)
    # Monday 2026-06-01 09:00 — a fixed anchor so every timestamp is deterministic.
    @base      = Time.zone.local(2026, 6, 1, 9, 0, 0)
    @user      = User.find(2) # jsmith — a person
    @anonymous = User.anonymous # the only author Redmine produces that is not a person
  end

  # --- helpers ---------------------------------------------------------------------------

  def make_issue(status_id: NEW)
    issue = Issue.new(project_id: 1, tracker_id: 1, author_id: 2, priority_id: 4,
                      status_id: status_id, subject: 'SLA update frequency test')
    issue.save!(validate: false)
    issue.update_column(:created_on, @base)
    issue.reload
  end

  def add_comment(issue, at:, notes: 'Working on it', private: false, user: @user)
    Journal.create!(journalized: issue, user: user, notes: notes,
                    private_notes: private, created_on: at)
  end

  # A journal carrying ONLY a field change — no notes at all. This is the case the whole
  # notes-present rule exists for: Redmine shows it in the same activity feed as a comment.
  def add_field_change(issue, at:, property: 'attr', prop_key: 'done_ratio',
                       old_value: '0', value: '30', notes: nil, user: @user)
    journal = Journal.new(journalized: issue, user: user, notes: notes, created_on: at)
    journal.details << JournalDetail.new(property: property, prop_key: prop_key,
                                         old_value: old_value, value: value)
    journal.save!
    journal
  end

  def add_status_change(issue, from:, to:, at:, notes: nil, user: @user)
    add_field_change(issue, at: at, prop_key: 'status_id',
                     old_value: from.to_s, value: to.to_s, notes: notes, user: user)
  end

  def at(offset_hours)
    @base + offset_hours.hours
  end

  # Evaluate one issue exactly as Sla::ResultClassifier does: same timeline and calendar clock.
  def evaluate(issue, target: FOUR_HOURS, from: @base, to:,
               non_human_author_ids: [], calculator: Sla::CalendarTimeCalculator.new)
    timeline = Sla::TimelineBuilder.new(issue.reload).build
    Sla::UpdateFrequencyEvaluator.new(timeline, target_seconds: target, calculator: calculator,
                                                from: from, to: to,
                                                non_human_author_ids: non_human_author_ids).evaluate
  end

  # --- what counts as a qualifying update ------------------------------------------------

  test "a journal with notes and no field changes counts" do
    issue = make_issue
    add_comment(issue, at: at(2))

    result = evaluate(issue, to: at(3))

    assert_equal 'met', result.state
    assert_equal 2 * 3600, result.max_gap_seconds, 'creation -> the comment'
    assert_equal 3600, result.current_gap_seconds, 'the comment -> now'
  end

  test "a journal with field changes but blank notes does NOT count" do
    issue = make_issue
    add_field_change(issue, at: at(2)) # % Done bumped, nobody said anything

    result = evaluate(issue, to: at(5))

    assert result.breached?, 'a silent field edit is not a status update'
    assert_equal 5 * 3600, result.max_gap_seconds, 'the gap runs straight through it'
    assert_equal 3600, result.deviation_seconds
  end

  test "a journal with BOTH a field change and notes counts" do
    issue = make_issue
    add_status_change(issue, from: NEW, to: 2, at: at(2), notes: 'Picked this up, investigating')

    result = evaluate(issue, to: at(5))

    assert_equal 'met', result.state, 'typed text is present, which is the only test that matters'
    assert_equal 3 * 3600, result.max_gap_seconds
  end

  test "a journal from a non-human author with notes does NOT count" do
    issue = make_issue
    add_comment(issue, at: at(2), notes: 'Logged anonymously', user: @anonymous)

    result = evaluate(issue, to: at(5), non_human_author_ids: [@anonymous.id])

    assert result.breached?
    assert_equal 5 * 3600, result.max_gap_seconds

    # The same journal from a person is a real update — the author is the only difference.
    assert_equal 'met', evaluate(issue, to: at(5), non_human_author_ids: []).state
  end

  # `journals.user_id` is NOT NULL in this schema, so an authorless journal cannot be created here
  # — this pins the defensive guard directly on the timeline instead. It matters because a timeline
  # is also built from imported/legacy histories, where the author may not survive the import.
  test "a comment event with no author does NOT count" do
    events = [Sla::TimelineBuilder::Event.new(type: :created, at: @base, to_status_id: NEW),
              Sla::TimelineBuilder::Event.new(type: :comment, at: at(2), user_id: nil)]
    timeline = Sla::TimelineBuilder::Timeline.new(events)
    result = Sla::UpdateFrequencyEvaluator.new(timeline, target_seconds: FOUR_HOURS,
                                                         calculator: Sla::CalendarTimeCalculator.new,
                                                         from: @base, to: at(5)).evaluate

    assert result.breached?, 'an authorless journal is not a person'
    assert_equal 5 * 3600, result.max_gap_seconds
  end

  test "a private note counts — this target measures work being reported, not a customer reply" do
    issue = make_issue
    add_comment(issue, at: at(2), notes: 'Internal: waiting on the vendor', private: true)

    assert_equal 'met', evaluate(issue, to: at(5)).state
  end

  # --- the cadence itself -----------------------------------------------------------------

  test "no qualifying updates at all since creation, still open past the target -> breached" do
    issue = make_issue

    result = evaluate(issue, to: at(9))

    assert result.breached?
    assert_equal 9 * 3600, result.max_gap_seconds
    assert_equal 5 * 3600, result.deviation_seconds
  end

  test "qualifying updates spaced under the target throughout -> not breached" do
    issue = make_issue
    [3, 6, 9, 12].each { |hour| add_comment(issue, at: at(hour)) }

    result = evaluate(issue, to: at(14))

    assert_equal 'met', result.state
    assert_equal 3 * 3600, result.max_gap_seconds
    assert_nil result.deviation_seconds
  end

  test "breached, updated, then quiet again past the target -> re-flags on the new silence" do
    issue = make_issue
    add_comment(issue, at: at(5)) # first silence: 5h, already over the 4h cadence

    recovered = evaluate(issue, to: at(6))
    assert recovered.breached?, 'the earlier silence still stands'
    assert_equal 3600, recovered.current_gap_seconds, 'but the ticket is not quiet right now'

    # ... and it goes quiet again, longer this time.
    result = evaluate(issue, to: at(12))

    assert result.breached?
    assert_equal 7 * 3600, result.max_gap_seconds, 'the second, longer silence'
    assert_equal 7 * 3600, result.current_gap_seconds, 're-flagged, not resting on the old breach'
    assert_equal 3 * 3600, result.deviation_seconds
  end

  test "updates from before the clock start do not reset the current cycle" do
    issue = make_issue
    add_comment(issue, at: at(2))                                 # previous cycle
    add_status_change(issue, from: RESOLVED, to: NEW, at: at(10))  # reopened, clock restarts

    result = evaluate(issue, from: at(10), to: at(15))

    assert result.breached?
    assert_equal 5 * 3600, result.max_gap_seconds, 'measured from the reopen, not from creation'
  end

  test "a comment added after the window's end does not close a gap the ticket really had" do
    issue = make_issue
    add_comment(issue, at: at(9)) # posted after resolution

    result = evaluate(issue, to: at(6)) # resolved at +6h

    assert result.breached?
    assert_equal 6 * 3600, result.max_gap_seconds
  end

  # --- the running silence's identity (the at-risk dedup key) --------------------------------

  test "current_gap_started_at is the last qualifying update, or the clock start when there is none" do
    issue = make_issue
    assert_equal @base, evaluate(issue, to: at(3)).current_gap_started_at

    add_comment(issue, at: at(2))
    assert_equal at(2), evaluate(issue, to: at(3)).current_gap_started_at

    # A non-human author's post is not an update, so it does not start a new silence either.
    add_comment(issue, at: at(2.5), user: @anonymous)
    assert_equal at(2), evaluate(issue, to: at(3), non_human_author_ids: [@anonymous.id])
                        .current_gap_started_at
  end

  test "a nil target never breaches but still reports the gaps" do
    issue = make_issue

    result = evaluate(issue, target: nil, to: at(48))

    assert_equal 'met', result.state
    assert_equal 48 * 3600, result.max_gap_seconds
    assert_nil result.deviation_seconds
  end
end
