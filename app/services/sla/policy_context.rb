# frozen_string_literal: true

require 'set'

module Sla
  # Per-project SLA configuration, resolved ONCE and reused across every issue in that
  # project. The sweep walks thousands of issues; resolving the effective policy, its
  # definitions, and its status-role mappings per issue would be a severe N+1. This value object
  # loads all of it in a handful of queries up front so `IssueEvaluator` can classify each issue
  # with zero further config lookups.
  #
  # It hard-codes nothing (Global Rule 1): the tracker/priority/status references all come from the
  # policy's own `sla_definitions` and `sla_status_mappings` rows, keyed by integer IDs
  # (Global Rule 2). When no policy is effective for the project, `#policy` is nil and the context
  # behaves as "not configured" — the classifier then yields `no_sla / not_configured`.
  class PolicyContext
    # Milestone roles, mirroring SlaStatusMapping::ROLES. Exposed to the classifier as symbols.
    ROLES = %w[created work_started resolved pause].freeze

    # Resolve the effective policy for +project+ (inheriting up the tree) and build a context.
    def self.for_project(project)
      new(SlaPolicy.effective_for(project))
    end

    attr_reader :policy, :status_roles

    def initialize(policy)
      @policy = policy
      if policy
        definitions        = policy.sla_definitions.to_a
        @definition_by_key = definitions.index_by { |d| [d.tracker_id, d.priority_id] }
        @configured_tracker_ids = definitions.map(&:tracker_id).to_set
        @status_roles      = build_status_roles(policy)
      else
        @definition_by_key = {}
        @configured_tracker_ids = Set.new
        @status_roles      = {}
      end
    end

    # Is this tracker under SLA at all (has any definition, regardless of priority)? Drives the
    # classifier's `not_configured` vs `not_tracked` distinction.
    def tracker_configured?(tracker_id)
      @configured_tracker_ids.include?(tracker_id)
    end

    # The SlaDefinition for this exact tracker x priority, or nil (⇒ not_tracked). The
    # admin-designated "unclassified" priority (Sla::PluginSettings#unclassified_priority_id) is
    # always treated as untracked, even if a stray SlaDefinition row exists for it — the plan and
    # the spec both call for this priority to be unconditionally excluded from SLA evaluation.
    def definition_for(tracker_id, priority_id)
      return nil if unclassified_priority?(priority_id)

      @definition_by_key[[tracker_id, priority_id]]
    end

    def unclassified_priority?(priority_id)
      priority_id.present? && priority_id == PluginSettings.unclassified_priority_id
    end

    # Journal authors that are not a real person — consumed by the Update Frequency target, which
    # only counts a comment as a status update when a human wrote it.
    #
    # That is Redmine's own anonymous user, and nothing else: an integration or REST-API account is
    # an ordinary user row, structurally identical to a person's, so identifying one would take an
    # admin-maintained list. There is deliberately no such list — this instance has no automated
    # posters, and a configuration surface nobody needs is one more thing to get wrong.
    #
    # Queried by STI type rather than through `User.anonymous`, which CREATES the anonymous user
    # when it is missing — this runs inside issue classification, and a read path must not write.
    # Memoised for the same reason everything else here is: the sweep classifies thousands of
    # issues against one context.
    def non_human_author_ids
      @non_human_author_ids ||= User.where(type: 'AnonymousUser').ids
    end

    private

    # {created: [id, ...], work_started: [...], resolved: [...], pause: [...]} from one query.
    def build_status_roles(policy)
      grouped = policy.sla_status_mappings.to_a.group_by(&:role)
      ROLES.each_with_object({}) do |role, roles|
        roles[role.to_sym] = Array(grouped[role]).map(&:status_id)
      end
    end
  end
end
