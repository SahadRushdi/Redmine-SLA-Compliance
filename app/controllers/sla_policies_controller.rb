# frozen_string_literal: true

# Saves the SLA Policy settings tab (Steps 4.2–4.5, 4.7, 4.8) and serves its two
# dynamic re-renders (tracker switch, clone prefill). Everything posted is whitelisted against
# live Redmine configuration; only IDs are stored (Global Rules 1–3).
class SlaPoliciesController < ApplicationController
  helper :sla_policies
  helper :sla_compliance

  before_action :find_project_by_project_id
  before_action :authorize

  # The tab is split into independently-savable sections (see SlaPoliciesHelper::SECTIONS, which
  # must stay in sync with this list). A submit carries the section it came from and may only
  # rewrite that section's slice of the policy — otherwise saving, say, General would post no
  # status_mappings and silently wipe every milestone status configured under Measurement Rules.
  POLICY_SECTIONS = %w[general measurement targets exclusions].freeze

  # Every policy scalar the sectioned form manages, in one place: it is both the strong-params
  # allow-list and the set copied when a section other than General creates the row
  # (see #seed_new_policy_scalars!). The two must not drift apart.
  POLICY_ATTRIBUTES = %i[enabled coverage_hours business_calendar_id first_response_rule
                         at_risk_threshold pause_enabled].freeze

  # Milestone roles owned by each section; roles NOT listed for the posted section are left
  # untouched. Every role in SlaStatusMapping::ROLES must appear in exactly one entry.
  SECTION_STATUS_ROLES = {
    'measurement' => %w[created work_started resolved],
    'exclusions' => %w[pause]
  }.freeze

  # GET /projects/:project_id/sla_policy/edit (js only):
  #   ?tracker_id=N  -> re-render the definition rows for that tracker (from saved data)
  #   ?clone_from=ID -> re-render the whole form prefilled from the source project's policy
  def edit
    if params[:clone_from].present?
      @sla_policy = build_clone_prefill(params[:clone_from])
      return render_404 unless @sla_policy
    end
    respond_to do |format|
      format.js
      format.html { redirect_to settings_project_path(@project, tab: 'sla_policy') }
    end
  end

  def update
    @sla_policy = SlaPolicy.find_or_initialize_by(project_id: @project.id)
    section = posted_section

    begin
      ActiveRecord::Base.transaction do
        seed_new_policy_scalars! if @sla_policy.new_record?
        @sla_policy.assign_attributes(policy_params)
        @sla_policy.save!
        replace_status_mappings!(SECTION_STATUS_ROLES.fetch(section, []))
        if section == 'targets'
          apply_clone_source!
          replace_tracker_definitions!
        end
      end
    rescue ActiveRecord::RecordInvalid => e
      flash[:error] = e.record.errors.full_messages.join(', ')
      return redirect_to settings_project_path(@project, tab: 'sla_policy', section: section)
    end

    flash[:notice] = l(:notice_successful_update)
    if section == 'targets' && params[:recalculate] == '1'
      SlaPolicyRecalculationJob.perform_later(@project.id)
      flash[:notice] = "#{flash[:notice]} #{l(:notice_sla_recalculation_queued)}"
    end
    redirect_to settings_project_path(@project, tab: 'sla_policy', section: section)
  end

  # B3 — "Revert to inherited policy": deletes THIS project's own policy row (cascading to its
  # definitions/status mappings, per their `dependent: :destroy`) so the project falls back to
  # its nearest ancestor's policy. Never touches `sla_results` — the recalculation job UPDATES
  # those rows in place under the now-inherited policy, it never deletes the cache.
  def destroy
    sla_policy = SlaPolicy.find_by(project_id: @project.id)
    if sla_policy
      sla_policy.destroy!
      SlaPolicyRecalculationJob.perform_later(@project.id)
      flash[:notice] = l(:notice_sla_reverted_to_inherited)
    end
    redirect_to settings_project_path(@project, tab: 'sla_policy')
  end

  private

  # Which section's form was submitted. Never trusted as-is — an unrecognised (or forged) value
  # falls back to the most restrictive section, which owns no status roles and no definitions.
  def posted_section
    POLICY_SECTIONS.include?(params[:section]) ? params[:section] : 'general'
  end

  # `fetch` rather than `require`: the SLA Targets section posts only definitions/clone params and
  # no sla_policy[...] key at all, which `require` would reject outright.
  def policy_params
    params.fetch(:sla_policy, {}).permit(*POLICY_ATTRIBUTES)
  end

  # Give a policy row being CREATED by a section that doesn't own every scalar the values that
  # section's form was showing, instead of the DB column defaults.
  #
  # Without this, `enabled` falls back to its default of FALSE whenever the row is first written
  # from any section other than General — and a disabled policy is an explicit "SLA off" that also
  # stops inheritance (SlaPolicy.effective_for). The damaging case is B3's Override: the user
  # presses "Override for this project" on a project inheriting an ENABLED ancestor policy, the
  # form renders prefilled from that ancestor with the SLA Tracking toggle ON, and then saving any
  # section other than General first would persist enabled=false — silently switching SLA off for
  # a project whose screen still showed it on. Seeding from the source the form was prefilled from
  # keeps what was displayed and what gets saved in agreement.
  #
  # Source order mirrors what the form actually rendered: the clone/Override source when one was
  # loaded, else the ancestor policy this project inherits today. With neither (the first policy
  # anywhere in the tree) the DB defaults stand — there the blank form shows the toggle OFF too,
  # so nothing diverges.
  def seed_new_policy_scalars!
    source = authorized_source_policy(params[:clone_source_id]) if params[:clone_source_id].present?
    source ||= SlaPolicy.source_for(@project).last
    return if source.nil?

    @sla_policy.assign_attributes(source.attributes.slice(*POLICY_ATTRIBUTES.map(&:to_s)))
  end

  def project_status_ids
    @project_status_ids ||= @project.rolled_up_statuses.map(&:id)
  end

  # Diff-replace the status rows for the roles the posted section owns. A role absent from the
  # params is cleared (deselecting every chip = milestone not evaluated) — which is exactly why
  # roles outside +roles+ are skipped entirely rather than passed through this loop.
  def replace_status_mappings!(roles)
    (roles.map(&:to_s) & SlaStatusMapping::ROLES).each do |role|
      wanted = Array(params.dig(:status_mappings, role)).map(&:to_i).uniq & project_status_ids
      scope = @sla_policy.sla_status_mappings.where(role: role)
      scope.where.not(status_id: wanted).delete_all
      (wanted - scope.pluck(:status_id)).each do |status_id|
        @sla_policy.sla_status_mappings.create!(role: role, status_id: status_id)
      end
    end
  end

  # Step 4.7 save half: when the form was prefilled from another project, copy ALL the source's
  # definitions first (restricted to this project's trackers); the posted tracker's rows below
  # then override the copied ones. Scalars/mappings arrive through the posted form itself.
  def apply_clone_source!
    return if params[:clone_source_id].blank?

    source = authorized_source_policy(params[:clone_source_id])
    return unless source

    @sla_policy.sla_definitions.delete_all
    unclassified_priority_id = Sla::PluginSettings.unclassified_priority_id
    source.sla_definitions.where(tracker_id: @project.trackers.ids)
          .where.not(priority_id: unclassified_priority_id).find_each do |definition|
      @sla_policy.sla_definitions.create!(
        tracker_id: definition.tracker_id,
        priority_id: definition.priority_id,
        response_seconds: definition.response_seconds,
        workaround_seconds: definition.workaround_seconds,
        resolution_seconds: definition.resolution_seconds,
        response_best_effort: definition.response_best_effort,
        workaround_best_effort: definition.workaround_best_effort,
        resolution_best_effort: definition.resolution_best_effort
      )
    end
  end

  # Step 4.4 save: replace the definitions of the posted tracker ONLY. Priorities are validated
  # against the live enumeration; seconds against the admin lookup (or the value previously
  # saved for that row, so a lookup edit doesn't invalidate existing policies). A row with all
  # targets blank creates no record — that priority is excluded.
  def replace_tracker_definitions!
    tracker_id = params.dig(:definitions, :tracker_id).to_i
    return unless @project.trackers.ids.include?(tracker_id)

    previous = @sla_policy.sla_definitions.where(tracker_id: tracker_id)
                          .index_by(&:priority_id)
    @sla_policy.sla_definitions.where(tracker_id: tracker_id).delete_all

    rows = params.dig(:definitions, :rows)
    return if rows.blank?

    allowed_priority_ids = IssuePriority.active.ids
    unclassified_priority_id = Sla::PluginSettings.unclassified_priority_id
    rows.each do |priority_id, targets|
      priority_id = priority_id.to_i
      next unless allowed_priority_ids.include?(priority_id)
      # Defense in depth: the form never renders inputs for the unclassified priority (it's
      # shown disabled), but never trust the client — reject a forged/stale submission for it too.
      next if priority_id == unclassified_priority_id

      attributes = {}
      SlaTargetOption::TARGET_TYPES.each do |target_type|
        raw = targets[target_type].presence
        next unless raw

        if raw == SlaPoliciesHelper::SLA_BEST_EFFORT_VALUE
          next unless SlaTargetOption.exists?(target_type: target_type, best_effort: true)

          attributes["#{target_type}_seconds"] = nil
          attributes["#{target_type}_best_effort"] = true
        else
          seconds = raw.to_i
          previously_saved = previous[priority_id]&.public_send("#{target_type}_seconds")
          if allowed_seconds_for(target_type).include?(seconds) || seconds == previously_saved
            attributes["#{target_type}_seconds"] = seconds
            attributes["#{target_type}_best_effort"] = false
          end
        end
      end
      next if attributes.empty?

      @sla_policy.sla_definitions.create!(
        { tracker_id: tracker_id, priority_id: priority_id }.merge(attributes)
      )
    end
  end

  def allowed_seconds_for(target_type)
    @allowed_seconds ||= SlaTargetOption.where(best_effort: false).group_by(&:target_type)
                                        .transform_values { |options| options.map(&:seconds) }
    @allowed_seconds.fetch(target_type.to_s, [])
  end

  # A source project is a valid prefill source (for both Step 4.7 "Clone from another project"
  # and B3's "Override for this project" inheritance-override) when either:
  #   * the user can directly edit ITS policy (the general clone case), or
  #   * it's an ANCESTOR of @project (the override case) — the user already passed `authorize`
  #     for @project itself, and that ancestor's policy already effectively governs @project's
  #     tickets today via inheritance, so reading it to prefill an override needs no separate
  #     permission grant on the ancestor project.
  def authorized_source_policy(source_project_id)
    source_project = Project.find_by(id: source_project_id)
    return nil unless source_project && source_project != @project &&
                      (User.current.allowed_to?(:edit_sla_policy, source_project) ||
                       @project.self_and_ancestors.include?(source_project))

    SlaPolicy.find_by(project_id: source_project.id)
  end

  # In-memory (unsaved) policy mirroring the source, used to prefill the form. Only references
  # valid in THIS project survive: mappings keep statuses the project actually uses, and
  # definitions keep trackers the project has enabled.
  def build_clone_prefill(source_project_id)
    source = authorized_source_policy(source_project_id)
    return nil unless source

    policy = SlaPolicy.new(
      project_id: @project.id,
      enabled: source.enabled,
      coverage_hours: source.coverage_hours,
      business_calendar_id: source.business_calendar_id,
      first_response_rule: source.first_response_rule,
      at_risk_threshold: source.at_risk_threshold,
      pause_enabled: source.pause_enabled
    )
    source.sla_status_mappings.each do |mapping|
      next unless project_status_ids.include?(mapping.status_id)
      policy.sla_status_mappings.build(role: mapping.role, status_id: mapping.status_id)
    end
    tracker_ids = @project.trackers.ids
    source.sla_definitions.each do |definition|
      next unless tracker_ids.include?(definition.tracker_id)
      policy.sla_definitions.build(
        tracker_id: definition.tracker_id,
        priority_id: definition.priority_id,
        response_seconds: definition.response_seconds,
        workaround_seconds: definition.workaround_seconds,
        resolution_seconds: definition.resolution_seconds,
        response_best_effort: definition.response_best_effort,
        workaround_best_effort: definition.workaround_best_effort,
        resolution_best_effort: definition.resolution_best_effort
      )
    end
    policy
  end
end
