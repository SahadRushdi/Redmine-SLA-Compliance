# frozen_string_literal: true

# Saves the SLA Policy settings tab (Steps 4.2–4.5, 4.7, 4.8) and serves its two
# dynamic re-renders (tracker switch, clone prefill). Everything posted is whitelisted against
# live Redmine configuration; only IDs are stored (Global Rules 1–3).
class SlaPoliciesController < ApplicationController
  helper :sla_policies
  helper :sla_compliance

  before_action :find_project_by_project_id
  before_action :authorize

  # The tab is split into independently-savable sections. This is the ALLOW-LIST of section keys a
  # submit may name; SlaPoliciesHelper::SECTIONS decides which are offered and in what order, and
  # every key here must appear there (pinned by a test). A submit carries the section it came from
  # and may only rewrite that section's slice of the policy — otherwise saving, say, General would post no
  # status_mappings and silently wipe every milestone status configured under Measurement Rules.
  POLICY_SECTIONS = %w[general measurement targets exclusions].freeze

  # The tri-state SLA on/off control offered to a project that inherits its configuration. It is
  # NOT one of POLICY_SECTIONS: those all write policy fields through #policy_params, whereas this
  # one writes nothing but `enabled` (+ the `inherits_config` marker) and can also DELETE the row.
  # Keeping it out of that list is what stops a forged `section=enablement` submit from reaching
  # the field-writing path at all.
  ENABLEMENT_SECTION = 'enablement'
  ENABLEMENT_CHOICES = %w[inherit enabled disabled].freeze

  # Every policy scalar the sectioned form manages, in one place: it is both the strong-params
  # allow-list and the set copied when a section other than General creates the row
  # (see #seed_scalars_from!). The two must not drift apart.
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
    return update_enablement if params[:section] == ENABLEMENT_SECTION

    @sla_policy = SlaPolicy.find_or_initialize_by(project_id: @project.id)
    section = posted_section

    begin
      ActiveRecord::Base.transaction do
        # A project whose configuration is inherited edits a form pre-filled from the ancestor, so
        # this save is a FORK: the whole inherited configuration is written as the project's own and
        # the posted section is applied on top. Captured before the row is touched, since assigning
        # below is exactly what stops it being inherited.
        source = forking_from_inherited? ? inherited_seed_source : nil
        seed_scalars_from!(source) if source
        @sla_policy.assign_attributes(policy_params)
        # Saving any policy section writes configuration onto this row, which by definition makes
        # it self-defining — the case that matters is a project that first used the tri-state
        # control (leaving a lightweight row) and then edited a field here.
        @sla_policy.inherits_config = false
        @sla_policy.save!
        # Before the posted section's own writes, so those override the copied values rather than
        # being overwritten by them.
        copy_configuration_from!(source, definitions: !cloning_definitions?(section)) if source
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

  # Tri-state SLA on/off for a project that inherits its configuration (Global Rule 5). Writes a
  # LIGHTWEIGHT policy row — `inherits_config: true`, carrying only the enabled decision — so the
  # project keeps following its ancestor's coverage/targets/status mappings. That is the whole
  # difference from "Override for this project", which forks the configuration outright.
  #
  # Deliberately does NOT go through #policy_params / #seed_scalars_from!: seeding would copy
  # the ancestor's scalars onto the row, and a row holding its own scalars is no longer lightweight
  # — the next parent change would silently stop reaching this project.
  def update_enablement
    return render_403 unless enablement_offered?

    case posted_enablement
    when 'inherit'  then revert_to_inherited_enablement
    when 'enabled'  then write_lightweight_policy(true)
    when 'disabled' then write_lightweight_policy(false)
    end

    redirect_to settings_project_path(@project, tab: 'sla_policy')
  end

  # The control only exists for a project whose configuration comes from an ancestor. A project
  # with a SELF-DEFINING row of its own uses General -> SLA Tracking instead, and must never be
  # able to reach this path — it would strip the row's `inherits_config = false` and orphan its
  # definitions and status mappings.
  def enablement_offered?
    own_policy = SlaPolicy.find_by(project_id: @project.id)
    return false if own_policy && !own_policy.inherits_config?

    # A lightweight row of our own stays revertible even if the ancestor that configured it has
    # since been deleted — otherwise the project would be stuck holding a row it cannot clear.
    own_policy.present? || SlaPolicy.config_source_for(@project).first.present?
  end

  def posted_enablement
    value = params.fetch(:sla_policy, {})[:enablement].to_s
    ENABLEMENT_CHOICES.include?(value) ? value : 'inherit'
  end

  def write_lightweight_policy(enabled)
    policy = SlaPolicy.find_or_initialize_by(project_id: @project.id)
    policy.assign_attributes(enabled: enabled, inherits_config: true)
    policy.save!
    SlaPolicyRecalculationJob.perform_later(@project.id)
    flash[:notice] = l(:notice_successful_update)
  end

  # Drops back to "whatever the ancestor decides". Only ever deletes a lightweight row — a full
  # override is reverted through #destroy's "Revert to inherited policy" button, which carries its
  # own confirmation because it discards a whole configuration.
  def revert_to_inherited_enablement
    policy = SlaPolicy.find_by(project_id: @project.id)
    return flash[:notice] = l(:notice_successful_update) if policy.nil?

    policy.destroy!
    SlaPolicyRecalculationJob.perform_later(@project.id)
    flash[:notice] = l(:notice_sla_reverted_to_inherited)
  end

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

  # Does this project not yet own its configuration? True with no row at all, and true for a
  # LIGHTWEIGHT row (which carries only the enabled decision) — both render a form pre-filled from
  # an ancestor, so both must copy that ancestor's configuration across when saved.
  def forking_from_inherited?
    @sla_policy.new_record? || @sla_policy.inherits_config?
  end

  # The policy the form the user just submitted was populated from: the clone source when one was
  # loaded, else the ancestor whose configuration this project inherits today. nil for the first
  # policy anywhere in the tree — there the form really is blank and the DB defaults are right.
  def inherited_seed_source
    source = authorized_source_policy(params[:clone_source_id]) if params[:clone_source_id].present?
    source || SlaPolicy.config_source_for(@project).last
  end

  # Scalars first, so the posted section's own fields (assigned after this) win.
  #
  # Without it, every scalar the posted section does not own falls back to the DB column default —
  # and for `enabled` that default is FALSE, an explicit "SLA off" that also stops inheritance
  # (SlaPolicy.effective_for). Saving, say, Measurement Rules on a project inheriting an ENABLED
  # policy would silently switch SLA off for a project whose screen showed it on.
  #
  # `enabled` is the one exception on an EXISTING row: a lightweight row's on/off decision is its
  # own (set through the tri-state control) and must not be overwritten by the ancestor's.
  def seed_scalars_from!(source)
    attributes = source.attributes.slice(*POLICY_ATTRIBUTES.map(&:to_s))
    attributes.delete('enabled') unless @sla_policy.new_record?
    @sla_policy.assign_attributes(attributes)
  end

  # Copy the source's status mappings and (unless the clone path below is about to do it) its
  # definitions onto the newly self-defining row. Only references valid in THIS project survive,
  # matching what the form displayed.
  #
  # This is what makes a sectioned save safe on an inherited policy: saving General alone would
  # otherwise leave a row with no milestone statuses and no targets — a policy that measures
  # nothing — for a project that was fully covered a moment earlier.
  def copy_configuration_from!(source, definitions: true)
    @sla_policy.sla_status_mappings.delete_all
    source.sla_status_mappings.each do |mapping|
      next unless project_status_ids.include?(mapping.status_id)

      @sla_policy.sla_status_mappings.create!(role: mapping.role, status_id: mapping.status_id)
    end
    return unless definitions

    @sla_policy.sla_definitions.delete_all
    copy_definitions_from!(source)
  end

  # Shared by the fork above and Step 4.7's clone: the source's definitions, restricted to trackers
  # this project has enabled and never including the unclassified priority (which can hold no
  # target — see Sla::PolicyContext#definition_for).
  def copy_definitions_from!(source)
    source.sla_definitions.where(tracker_id: @project.trackers.ids)
          .where.not(priority_id: Sla::PluginSettings.unclassified_priority_id)
          .find_each do |definition|
      @sla_policy.sla_definitions.create!(
        definition.attributes.slice(*SlaDefinition::COPY_ATTRIBUTES)
      )
    end
  end

  # True when #apply_clone_source! is about to replace every definition from the same source, so
  # copying them here first would just be thrown away.
  def cloning_definitions?(section)
    section == 'targets' && params[:clone_source_id].present?
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
    copy_definitions_from!(source)
  end

  # Step 4.4 save: replace the definitions of the POSTED trackers only — the SLA Targets section
  # shows one Priority Targets table per tracker chosen in its picker and saves them all together.
  #
  # Trackers absent from the submit are left exactly as they are: the picker chooses what is on
  # screen and therefore editable, not which trackers have an SLA. Clearing a tracker's targets is
  # done by setting its rows to "not tracked" (all-blank rows create no record), not by hiding it —
  # so deselecting can never silently discard stored targets.
  def replace_tracker_definitions!
    tracker_ids = Array(params.dig(:definitions, :tracker_ids)).map(&:to_i).uniq &
                  @project.trackers.ids
    return if tracker_ids.empty?

    previous = @sla_policy.sla_definitions.where(tracker_id: tracker_ids).group_by(&:tracker_id)
    @sla_policy.sla_definitions.where(tracker_id: tracker_ids).delete_all

    tracker_ids.each do |tracker_id|
      rows = params.dig(:definitions, :rows, tracker_id.to_s)
      next if rows.blank?

      create_tracker_definitions!(tracker_id, rows,
                                  Array(previous[tracker_id]).index_by(&:priority_id))
    end
  end

  # One tracker's posted rows. Priorities are validated against the live enumeration; seconds
  # against the admin lookup (or the value previously saved for that row, so a lookup edit doesn't
  # invalidate existing policies). A row with all targets blank creates no record — that priority
  # is excluded.
  def create_tracker_definitions!(tracker_id, rows, previous)
    allowed_priority_ids = IssuePriority.active.ids
    unclassified_priority_id = Sla::PluginSettings.unclassified_priority_id

    rows.each do |priority_id, targets|
      priority_id = priority_id.to_i
      next unless allowed_priority_ids.include?(priority_id)
      # Defense in depth: the form never renders inputs for the unclassified priority (it's
      # shown disabled), but never trust the client — reject a forged/stale submission for it too.
      next if priority_id == unclassified_priority_id

      attributes = definition_targets(targets, previous[priority_id])
      next if attributes.empty?

      @sla_policy.sla_definitions.create!(
        { tracker_id: tracker_id, priority_id: priority_id }.merge(attributes)
      )
    end
  end

  def definition_targets(targets, previous_definition)
    SlaTargetOption::TARGET_TYPES.each_with_object({}) do |target_type, attributes|
      raw = targets[target_type].presence
      next unless raw

      if raw == SlaPoliciesHelper::SLA_BEST_EFFORT_VALUE
        next unless SlaTargetOption.exists?(target_type: target_type, best_effort: true)

        attributes["#{target_type}_seconds"] = nil
        attributes["#{target_type}_best_effort"] = true
      else
        seconds = raw.to_i
        previously_saved = previous_definition&.public_send("#{target_type}_seconds")
        if allowed_seconds_for(target_type).include?(seconds) || seconds == previously_saved
          attributes["#{target_type}_seconds"] = seconds
          attributes["#{target_type}_best_effort"] = false
        end
      end
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

  # In-memory (unsaved) policy mirroring the source, used to prefill the form. Shared with the
  # settings tab, which builds the same thing to show an inheriting project its ancestor's
  # configuration as editable fields (SlaPoliciesHelper#sla_policy_for_form).
  def build_clone_prefill(source_project_id)
    Sla::PolicyPrefill.call(project: @project,
                            source: authorized_source_policy(source_project_id))
  end
end
