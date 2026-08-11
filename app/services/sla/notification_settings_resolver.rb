# frozen_string_literal: true

module Sla
  # Resolves each notification channel independently. A project can therefore own its Google Chat
  # webhook while inheriting at-risk email from a parent and using the instance default for stale
  # email. Disabled/blank values mean "continue to the next source", not an explicit opt-out.
  class NotificationSettingsResolver
    Resolution = Struct.new(:setting, :source, :source_project, keyword_init: true) do
      def configured?
        setting.present?
      end

      def inherited?
        %i[parent admin].include?(source)
      end
    end

    CHANNEL_PREDICATES = {
      google_chat: ->(setting) { setting.google_chat_webhook.present? },
      at_risk_email: ->(setting) { setting.at_risk_email_enabled? },
      stale_email: ->(setting) { setting.stale_email_enabled? }
    }.freeze

    # Builds resolvers for a sweep with one query per hierarchy depth plus two settings queries,
    # regardless of target-project count. This avoids turning parent fallback into an
    # ancestors/settings N+1 without loading unrelated Redmine project trees.
    def self.for_projects(projects)
      targets = projects.to_a
      project_index = targets.index_by(&:id)
      pending_parent_ids = targets.filter_map(&:parent_id).uniq
      while pending_parent_ids.any?
        parents = Project.where(id: pending_parent_ids).to_a
        parents.each { |parent| project_index[parent.id] = parent }
        pending_parent_ids = parents.filter_map(&:parent_id).uniq - project_index.keys
      end
      settings = SlaNotificationSetting.where(project_id: project_index.keys).index_by(&:project_id)
      global = SlaNotificationSetting.global

      targets.index_with do |project|
        new(project, project_index: project_index, settings: settings, global: global)
      end
    end

    def initialize(project, project_index: nil, settings: nil, global: :not_loaded)
      @project = project
      # Redmine's nested-set scope is root-first; fallback precedence is current project first,
      # followed by the nearest parent and then progressively more distant ancestors.
      @projects = project_index ? chain_from_index(project, project_index) :
                                  [project] + project.ancestors.to_a.reverse
      @settings = settings ||
                  SlaNotificationSetting.where(project_id: @projects.map(&:id)).index_by(&:project_id)
      @global = global == :not_loaded ? SlaNotificationSetting.global : global
    end

    def resolve(channel)
      predicate = CHANNEL_PREDICATES.fetch(channel.to_sym)
      @projects.each do |project|
        setting = @settings[project.id]
        next unless setting && predicate.call(setting)

        return Resolution.new(setting: setting,
                              source: project.id == @project.id ? :project : :parent,
                              source_project: project)
      end

      return Resolution.new unless @global && predicate.call(@global)

      Resolution.new(setting: @global, source: :admin)
    end

    private

    def chain_from_index(project, project_index)
      chain = []
      current = project_index[project.id] || project
      while current
        chain << current
        current = project_index[current.parent_id]
      end
      chain
    end
  end
end
