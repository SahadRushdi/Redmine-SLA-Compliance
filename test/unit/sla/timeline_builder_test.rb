# frozen_string_literal: true

require_relative '../../test_helper'

# Phase 2 · Step 2.1 — Timeline reconstruction from journals.
#
# Exercises Sla::TimelineBuilder over hand-crafted journal histories built on a fresh issue.
# All records are created inside Redmine's transactional tests and rolled back — nothing is
# persisted. Core status fixtures: New=1, Assigned=2, Resolved=3, Closed=5.
class Sla::TimelineBuilderTest < ActiveSupport::TestCase
  fixtures :projects, :users, :issues, :issue_statuses, :trackers, :enumerations,
           :roles, :members, :member_roles

  NEW      = 1
  ASSIGNED = 2
  RESOLVED = 3

  setup do
    User.current = User.find(2) # jsmith
    # Monday 2026-06-01 09:00 — a fixed anchor so every event timestamp is deterministic.
    @base = Time.zone.local(2026, 6, 1, 9, 0, 0)
    @user = User.find(2)
  end

  # --- helpers --------------------------------------------------------------------------

  def make_issue(status_id: NEW)
    issue = Issue.new(project_id: 1, tracker_id: 1, author_id: 2, priority_id: 4,
                      status_id: status_id, subject: 'SLA timeline test')
    issue.save!(validate: false)
    issue.update_column(:created_on, @base) # skip callbacks; pin the creation time
    issue.reload
  end

  # A status transition (JournalDetail property='attr', prop_key='status_id'). Optionally
  # carries a note in the SAME journal. Keep `private:` false when a note is present so
  # Redmine's split_private_notes doesn't split it into two journals.
  def add_status_change(issue, from:, to:, at:, notes: nil, private: false, user: @user)
    journal = Journal.new(journalized: issue, user: user, notes: notes,
                          private_notes: private, created_on: at)
    journal.details << JournalDetail.new(property: 'attr', prop_key: 'status_id',
                                         old_value: from&.to_s, value: to&.to_s)
    journal.save!
    journal
  end

  def add_comment(issue, notes:, at:, private: false, user: @user)
    Journal.create!(journalized: issue, user: user, notes: notes,
                    private_notes: private, created_on: at)
  end

  def build(issue)
    Sla::TimelineBuilder.new(issue.reload).build
  end

  def at(offset_hours)
    @base + offset_hours.hours
  end

  # --- 1. No journals -------------------------------------------------------------------

  test "issue with no journals yields a single creation event at created_on" do
    issue = make_issue(status_id: NEW)
    tl = build(issue)

    assert_equal 1, tl.events.size
    created = tl.events.first
    assert_equal :created, created.type
    assert_equal @base.to_i, created.at.to_i
    assert_equal NEW, tl.initial_status_id
    assert_empty tl.status_changes
    assert_empty tl.comments
  end

  # --- 2. Single status change ----------------------------------------------------------

  test "initial status comes from the first change's old_value, not the current status" do
    issue = make_issue(status_id: NEW)
    add_status_change(issue, from: NEW, to: ASSIGNED, at: at(1))
    issue.update_column(:status_id, ASSIGNED) # current state moved on

    tl = build(issue)

    assert_equal [:created, :status_change], tl.events.map(&:type)
    assert_equal NEW, tl.initial_status_id # derived from old_value, not current status
    change = tl.status_changes.first
    assert_equal NEW, change.from_status_id
    assert_equal ASSIGNED, change.to_status_id
    assert_equal at(1).to_i, change.at.to_i
  end

  # --- 3. Comments only, with private-note flagging -------------------------------------

  test "comment events are ordered and private notes are flagged" do
    issue = make_issue(status_id: NEW)
    add_comment(issue, notes: 'public reply', at: at(1))
    add_comment(issue, notes: 'internal only', at: at(2), private: true)

    tl = build(issue)

    assert_empty tl.status_changes
    assert_equal 2, tl.comments.size
    assert_equal [false, true], tl.comments.map(&:private_note)
    assert_equal [at(1).to_i, at(2).to_i], tl.comments.map { |c| c.at.to_i }
  end

  # --- 4. Comment + status change in one journal ----------------------------------------

  test "a journal carrying both a note and a status change emits both, change before note" do
    issue = make_issue(status_id: NEW)
    add_status_change(issue, from: NEW, to: ASSIGNED, at: at(1), notes: 'note + change')

    tl = build(issue)

    types = tl.events.map(&:type)
    assert_equal [:created, :status_change, :comment], types
    change_idx  = types.index(:status_change)
    comment_idx = types.index(:comment)
    assert change_idx < comment_idx, 'status change must sort before the note at same time'
    assert_equal 1, tl.status_changes.size
    assert_equal 1, tl.comments.size
    assert_equal at(1).to_i, tl.comments.first.at.to_i
  end

  # --- 5. Reopened case -----------------------------------------------------------------

  test "reopened issue reconstructs every transition in order with correct from/to ids" do
    issue = make_issue(status_id: NEW)
    add_status_change(issue, from: NEW,      to: ASSIGNED, at: at(1))
    add_status_change(issue, from: ASSIGNED, to: RESOLVED, at: at(2))
    add_status_change(issue, from: RESOLVED, to: NEW,      at: at(3)) # reopened
    add_status_change(issue, from: NEW,      to: RESOLVED, at: at(4))

    tl = build(issue)

    assert_equal NEW, tl.initial_status_id
    assert_equal [ASSIGNED, RESOLVED, NEW, RESOLVED], tl.status_changes.map(&:to_status_id)
    assert_equal [NEW, ASSIGNED, RESOLVED, NEW],      tl.status_changes.map(&:from_status_id)
    # The reopen (back into NEW) is present as its own span for Step 2.6 to act on.
    assert_equal [NEW, ASSIGNED, RESOLVED, NEW, RESOLVED],
                 tl.status_intervals.map { |i| i[:status_id] }
  end

  # --- 6. Ordering safety (journals inserted out of chronological order) -----------------

  test "events are ordered chronologically regardless of insertion order" do
    issue = make_issue(status_id: NEW)
    add_status_change(issue, from: ASSIGNED, to: RESOLVED, at: at(3)) # inserted first
    add_status_change(issue, from: NEW,      to: ASSIGNED, at: at(1)) # inserted second

    tl = build(issue)

    times = tl.events.map { |e| e.at.to_i }
    assert_equal times.sort, times
    assert_equal [ASSIGNED, RESOLVED], tl.status_changes.map(&:to_status_id)
  end

  # --- 7. Initial-status derivation past a leading comment ------------------------------

  test "a comment before the first status change does not affect the initial status" do
    issue = make_issue(status_id: NEW)
    add_comment(issue, notes: 'triage note', at: at(1))
    add_status_change(issue, from: ASSIGNED, to: RESOLVED, at: at(2))
    issue.update_column(:status_id, RESOLVED)

    tl = build(issue)

    # old_value of the first (and only) status change wins over both the comment and the
    # issue's current status.
    assert_equal ASSIGNED, tl.initial_status_id
  end

  # --- 8. status_intervals spans --------------------------------------------------------

  test "status_intervals reconstructs contiguous spans with an open final span" do
    issue = make_issue(status_id: NEW)
    add_status_change(issue, from: NEW,      to: ASSIGNED, at: at(2))
    add_status_change(issue, from: ASSIGNED, to: RESOLVED, at: at(5))

    intervals = build(issue).status_intervals

    assert_equal 3, intervals.size
    assert_equal [NEW, ASSIGNED, RESOLVED], intervals.map { |i| i[:status_id] }
    assert_equal [@base.to_i, at(2).to_i, at(5).to_i], intervals.map { |i| i[:started_at].to_i }
    # Each span ends where the next begins; the final span is still open.
    assert_equal at(2).to_i, intervals[0][:ended_at].to_i
    assert_equal at(5).to_i, intervals[1][:ended_at].to_i
    assert_nil intervals[2][:ended_at]
  end
end
