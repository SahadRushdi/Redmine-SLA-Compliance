# frozen_string_literal: true

module Sla
  # Phase 3 — The single Issue → SLA `Result` entry point. This is the orchestrator the engine's
  # `ResultClassifier` (Step 2.6) always needed but deliberately did NOT include: it resolves the
  # issue's effective policy / definition / status-roles (via `PolicyContext`), rebuilds the issue's
  # timeline from journals (`TimelineBuilder`), and runs the classifier — returning its plain `Result` struct.
  #
  # It performs NO database writes (persistence is `ResultStore`'s job), so it stays cheap and
  # unit-testable over real journal fixtures. Pass a shared `context` when evaluating many issues in
  # the same project (the sweep) to avoid re-resolving the policy per issue.
  class IssueEvaluator
    def initialize(issue, context: nil, now: Time.current)
      @issue   = issue
      @context = context || PolicyContext.for_project(issue.project)
      @now     = now
    end

    # @return [Sla::ResultClassifier::Result]
    def call
      timeline = TimelineBuilder.new(@issue).build

      ResultClassifier.new(
        timeline:             timeline,
        policy:               @context.policy,
        definition:           @context.definition_for(@issue.tracker_id, @issue.priority_id),
        tracker_configured:   @context.tracker_configured?(@issue.tracker_id),
        status_roles:         @context.status_roles,
        # The issue's live state, which the journal timeline alone cannot supply: needed so
        # ResultClassifier#closed_at can still recognise a ticket that is SITTING in a resolved
        # status without a recorded transition into it, and so a project with no policy at all can
        # fall back to Redmine's own closed_on.
        current_status_id:    @issue.status_id,
        fallback_resolved_at: @issue.closed_on,
        # Passed as a callable, not a value: the Update Frequency target has to know which journal
        # authors are not real people, but that lookup is a query and most issues never reach it
        # (no cadence target for their priority). Deferring it means an ordinary issue save pays
        # nothing, while the sweep — which does hit it — resolves it once per project context.
        non_human_author_ids: -> { @context.non_human_author_ids },
        now:                  @now
      ).classify
    end
  end
end
