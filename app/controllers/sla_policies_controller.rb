# frozen_string_literal: true

# Saves the SLA Policy settings tab (Steps 4.2–4.5, 4.7, 4.8) and serves its two
# dynamic re-renders (tracker switch, clone prefill). Everything posted is whitelisted against
# live Redmine configuration; only IDs are stored (Global Rules 1–3).
class SlaPoliciesController < ApplicationController
  helper :sla_policies
  helper :sla_compliance

  before_action :find_project_by_project_id
  before_action :authorize

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

    begin
      ActiveRecord::Base.transaction do
        @sla_policy.assign_attributes(policy_params)
        @sla_policy.save!
        replace_status_mappings!
        apply_clone_source!
        replace_tracker_definitions!
      end
    rescue ActiveRecord::RecordInvalid => e
      flash[:error] = e.record.errors.full_messages.join(', ')
      return redirect_to settings_project_path(@project, tab: 'sla_policy')
    end

    flash[:notice] = l(:notice_successful_update)
    if params[:recalculate] == '1'
      SlaPolicyRecalculationJob.perform_later(@project.id)
      flash[:notice] = "#{flash[:notice]} #{l(:notice_sla_recalculation_queued)}"
    end
    redirect_to settings_project_path(@project, tab: 'sla_policy')
  end

  private

  def policy_params
    params.require(:sla_policy)
          .permit(:enabled, :coverage_hours, :business_calendar_id, :first_response_rule,
                  :at_risk_threshold, :pause_enabled)
  end

  def project_status_ids
    @project_status_ids ||= @project.rolled_up_statuses.map(&:id)
  end

  # Diff-replace the status rows per milestone role. A role absent from the params is cleared
  # (deselecting every chip = milestone not evaluated).
  def replace_status_mappings!
    SlaStatusMapping::ROLES.each do |role|
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
    source.sla_definitions.where(tracker_id: @project.trackers.ids).find_each do |definition|
      @sla_policy.sla_definitions.create!(
        tracker_id: definition.tracker_id,
        priority_id: definition.priority_id,
        response_seconds: definition.response_seconds,
        workaround_seconds: definition.workaround_seconds,
        resolution_seconds: definition.resolution_seconds
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
    rows.each do |priority_id, targets|
      priority_id = priority_id.to_i
      next unless allowed_priority_ids.include?(priority_id)

      attributes = {}
      SlaTargetOption::TARGET_TYPES.each do |target_type|
        raw = targets[target_type].presence
        next unless raw

        seconds = raw.to_i
        previously_saved = previous[priority_id]&.public_send("#{target_type}_seconds")
        if allowed_seconds_for(target_type).include?(seconds) || seconds == previously_saved
          attributes["#{target_type}_seconds"] = seconds
        end
      end
      next if attributes.empty?

      @sla_policy.sla_definitions.create!(
        { tracker_id: tracker_id, priority_id: priority_id }.merge(attributes)
      )
    end
  end

  def allowed_seconds_for(target_type)
    @allowed_seconds ||= SlaTargetOption.all.group_by(&:target_type)
                                        .transform_values { |options| options.map(&:seconds) }
    @allowed_seconds.fetch(target_type.to_s, [])
  end

  def authorized_source_policy(source_project_id)
    source_project = Project.find_by(id: source_project_id)
    return nil unless source_project && source_project != @project &&
                      User.current.allowed_to?(:edit_sla_policy, source_project)

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
        resolution_seconds: definition.resolution_seconds
      )
    end
    policy
  end
end
