# frozen_string_literal: true

module Sla
  # Historical / project-wide recompute.
  # Recomputes the `sla_results` cache for EVERY issue in a project (and, by default, its
  # descendants, which inherit the policy). This is the reusable mechanism behind the Phase 4.8
  # "recalculate historical tickets" checkbox: a normal policy save stays forward-only (only future
  # issue changes trigger the event-driven hook), and this runs only when explicitly invoked.
  #
  # The effective policy is resolved once per project (`PolicyContext`) and shared across that
  # project's issues to avoid re-resolving inheritance per issue.
  class ProjectRecalculator
    # @return [Integer] number of issues recalculated
    def self.run(project, include_descendants: true, now: Time.current)
      new(project, include_descendants: include_descendants, now: now).run
    end

    def initialize(project, include_descendants: true, now: Time.current)
      @project             = project
      @include_descendants = include_descendants
      @now                 = now
    end

    def run
      count = 0
      target_projects.each do |proj|
        context = PolicyContext.for_project(proj)
        issues_for(proj).find_each do |issue|
          ResultStore.recalculate(issue, context: context, now: @now)
          count += 1
        end
      end
      count
    end

    private

    def target_projects
      @include_descendants ? @project.self_and_descendants.to_a : [@project]
    end

    def issues_for(proj)
      proj.issues.includes(:project, :tracker, :priority, :status)
    end
  end
end
