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
        timeline:           timeline,
        policy:             @context.policy,
        definition:         @context.definition_for(@issue.tracker_id, @issue.priority_id),
        tracker_configured: @context.tracker_configured?(@issue.tracker_id),
        status_roles:       @context.status_roles,
        now:                @now
      ).classify
    end
  end
end
