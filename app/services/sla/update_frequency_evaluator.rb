# frozen_string_literal: true

module Sla
  # Update Frequency — the fourth SLA target, and the only RECURRING one.
  #
  # Response / Workaround / Resolution each measure "clock start → one milestone event, once".
  # This one is a heartbeat: someone must post a real status comment at least every N seconds for
  # as long as the ticket is open. A ticket comfortably inside its Resolution target still breaches
  # this if it goes quiet for too long, and a ticket that breached, was updated, then went quiet
  # again breaches again — so what is measured is the LARGEST quiet gap, not a single elapsed span.
  #
  # WHAT COUNTS AS A QUALIFYING UPDATE
  # Redmine records comments and field changes as the same object (a Journal) and shows them in one
  # activity feed, but a journal carries two separable things: `notes` (text a person typed) and
  # `journal_details` (structured field changes). A journal can have details and NO notes — someone
  # switching the tracker or bumping % Done without saying anything. That is not a status update and
  # must not reset the heartbeat. A journal with notes counts whether or not it also carries a field
  # change: what matters is only that real typed text is present, plus a human author.
  #
  # Both halves are already available without re-reading journals (the plan's "read the timeline,
  # don't re-fetch"): Sla::TimelineBuilder emits a `:comment` event for EXACTLY the journals whose
  # notes are present (`next if journal.notes.blank?`) and carries the `user_id` on it. So this
  # class applies only the human-author half — see #human_author?.
  #
  # PRIVATE NOTES COUNT HERE. That is a deliberate difference from Sla::FirstResponseDetector, which
  # excludes them: first response measures a CUSTOMER-FACING reply, whereas this measures whether the
  # ticket is being worked and reported on at all — an internal note is a real status update.
  #
  # PAUSES are excluded from every gap via the same Sla::PauseCalculator the other three targets use
  # (no special-casing): a ticket parked in "Waiting on Client" is not going quiet on the team.
  #
  # Pure and side-effect free: reads a timeline, writes nothing, hard-codes no status/priority/user.
  class UpdateFrequencyEvaluator
    # Same shape the classifier already composes for the other three targets: a state plus a
    # deviation, with the two figures the state was derived from.
    #   max_gap_seconds     — the longest quiet gap in the measured window; what a breach is judged on.
    #   current_gap_seconds — the gap running right now (last qualifying update → the window's end).
    #     This, NOT the max, is what the at-risk warning must look at: a ticket that once went quiet
    #     for 7 of its 8 allowed hours but was updated a minute ago is not about to breach.
    #   current_gap_started_at — the instant that gap began (the last qualifying update, or the clock
    #     start when there has been none). It identifies WHICH silence is running, which is what lets
    #     a recurring at-risk warning be de-duplicated per silence instead of once per measurement
    #     cycle — see Sla::Sweep#queue_at_risk.
    Result = Struct.new(:state, :deviation_seconds, :max_gap_seconds, :current_gap_seconds,
                        :current_gap_started_at, keyword_init: true) do
      def breached?
        state == 'breached'
      end
    end

    # @param timeline [Sla::TimelineBuilder::Timeline] full journal history, already built.
    # @param target_seconds [Integer, nil] the configured cadence; nil ⇒ nothing to breach (a Best
    #   Effort cadence, whose elapsed gaps are still worth reporting).
    # @param pause [Sla::PauseCalculator] the classifier's own, so paused time and coverage mode
    #   (calendar vs business hours) are subtracted exactly as they are for the other targets.
    # @param from [Time] clock start — creation, or the latest reopen (the classifier's cycle start).
    # @param to [Time] the window's end: the resolution instant for a resolved ticket, `now` for an
    #   open one. A resolved ticket's trailing silence still counts, for the same reason the other
    #   three milestones stop measuring at resolution rather than at `now`.
    # @param non_human_author_ids [Array<Integer>] authors that are not a person (see #human_author?).
    def initialize(timeline, target_seconds:, pause:, from:, to:, non_human_author_ids: [])
      @timeline             = timeline
      @target               = target_seconds
      @pause                = pause
      @from                 = from
      @to                   = to
      @non_human_author_ids = Array(non_human_author_ids)
    end

    # @return [Result]
    def evaluate
      updates  = qualifying_update_times
      gaps     = gap_seconds(updates)
      max_gap  = gaps.max || 0
      breached = @target.present? && max_gap > @target

      Result.new(
        state:                  breached ? 'breached' : 'met',
        deviation_seconds:      breached ? max_gap - @target : nil,
        max_gap_seconds:        max_gap,
        current_gap_seconds:    gaps.last || 0,
        current_gap_started_at: updates.last || @from
      )
    end

    private

    # Every gap in the window, paused time removed from each: clock start → first qualifying update,
    # each consecutive pair, and the last one → the window's end. With no qualifying updates at all
    # this is the single span [from, to] — silence since creation, which is exactly the ticket the
    # rule exists to catch.
    def gap_seconds(updates)
      boundaries = [@from] + updates + [@to]
      boundaries.each_cons(2).map { |started, ended| @pause.net_elapsed(started, ended) }
    end

    # Qualifying updates inside this measurement cycle, in order. Bounded by `from` so a reopened
    # ticket is measured from its reopen (updates belonging to the previous cycle can't reset the
    # new one), and by `to` so a comment added after resolution doesn't retroactively close a gap
    # the ticket really had while it was open.
    def qualifying_update_times
      @timeline.comments
               .select { |event| human_author?(event) && event.at > @from && event.at <= @to }
               .map(&:at)
               .sort
    end

    # A real person. Two exclusions, no hard-coded names or logins (Global Rule 1), IDs only
    # (Global Rule 2):
    #   * no author at all — a journal Redmine wrote without a user;
    #   * a non-human author, which in practice means Redmine's own anonymous user
    #     (Sla::PolicyContext#non_human_author_ids).
    # There is deliberately no admin-managed list of service/API accounts: an integration posting
    # through the REST API is an ordinary Redmine user row, indistinguishable from a person's, so
    # excluding one would require naming it — and on this instance every ticket update is written
    # by a person, which makes that a configuration surface with nothing to configure.
    def human_author?(event)
      event.user_id.present? && !@non_human_author_ids.include?(event.user_id)
    end
  end
end
