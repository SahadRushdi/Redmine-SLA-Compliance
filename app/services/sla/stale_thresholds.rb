# frozen_string_literal: true

module Sla
  # {project_id => inactivity threshold in days} for a set of projects, resolved exactly as
  # SlaPolicy.stale_threshold_days_for resolves a single one: the project's own value, else the
  # nearest ancestor that set one. Projects that resolve to nothing are absent from the hash — "no
  # threshold configured", which the Stale card reports rather than counting against a number
  # nobody chose.
  #
  # Exists as a separate object purely because of HOW MANY projects the dashboard asks about at
  # once. `SlaPolicy.stale_threshold_days_for` walks one project's branch with two queries; the
  # cross-project dashboard would repeat that per project on every page load. This resolves the
  # whole set in TWO queries total, by loading the parent links and the configured values once and
  # walking the chains in memory. Same rules, same results — asserted against the model method in
  # the tests, so the two cannot drift.
  class StaleThresholds
    def self.for_projects(project_ids)
      new(project_ids).call
    end

    def initialize(project_ids)
      @project_ids = Array(project_ids).compact.uniq
    end

    # @return [Hash{Integer => Integer}] project_id => days, omitting unresolved projects.
    def call
      return {} if @project_ids.empty?

      @project_ids.each_with_object({}) do |project_id, resolved|
        days = inherited_days(project_id)
        resolved[project_id] = days if days.present?
      end
    end

    private

    # Walk project → parent → … until a project carries its own configured value. The `seen` guard
    # is for a malformed tree only: a cycle here would otherwise loop forever inside a page render.
    def inherited_days(project_id)
      seen = {}
      current = project_id
      while current && !seen[current]
        seen[current] = true
        value = configured_days[current]
        return value if value

        current = parent_ids[current]
      end
      nil
    end

    # One query each, for the whole set — the reason this class exists.
    def configured_days
      @configured_days ||=
        SlaPolicy.where.not(stale_threshold_days: nil).pluck(:project_id, :stale_threshold_days).to_h
    end

    # The full id → parent_id map rather than one ancestor query per project: it is a single small
    # column pair (Redmine instances have projects in the hundreds at most), and it makes the walk
    # above pure memory regardless of how deep or how many the branches are.
    def parent_ids
      @parent_ids ||= Project.pluck(:id, :parent_id).to_h
    end
  end
end
