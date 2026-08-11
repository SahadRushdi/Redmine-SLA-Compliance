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
  POLICY_ATTRIBUTES = %i[enabled coverage_hours first_response_rule
                         at_risk_threshold stale_threshold_days pause_enabled].freeze

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

      # The Notifications panel is re-rendered from this when it is set (see edit.js.erb and
      # SlaPoliciesHelper#sla_notification_setting_for_form, which this pre-empts). nil ⇒ the panel
      # is left exactly as it is, which is what must happen when the copy would be refused.
      @sla_notification_setting = build_clone_notification_prefill(params[:clone_from])
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
    # Resolved ONCE and threaded through every consumer below rather than memoised on the
    # controller: an instance variable would tie three methods together invisibly, and a controller
    # instance is not guaranteed to serve exactly one request (ActionController::TestCase reuses
    # one across calls, which is enough to make a stale nil look like "no clone was requested").
    clone_source = clone_source_policy
    notifications_skipped = false

    begin
      ActiveRecord::Base.transaction do
        # Two different reasons to copy another project's configuration wholesale, one code path:
        #
        #   * a CLONE — the user picked a source, pressed Load, and reviewed every section
        #     pre-filled from it. "Clone" means the whole policy, not the section that happens to
        #     host the button, and it applies whether or not this project already had a policy of
        #     its own (before, an existing policy took the `source = nil` branch and only its
        #     targets were copied — everything else silently stayed behind);
        #   * a FORK — a project whose configuration is inherited saves for the first time, and
        #     must end up with the complete configuration it had a moment earlier plus the change
        #     just made (Step 6A.3).
        #
        # The clone wins when both apply: it is the explicit choice. `forking_from_inherited?` is
        # read before the row is touched, since assigning below is exactly what stops it being
        # inherited.
        source = clone_source || (forking_from_inherited? ? inherited_seed_source : nil)
        seed_scalars_from!(source, clone: clone_source.present?) if source
        @sla_policy.assign_attributes(policy_params)
        # Provenance, recorded here rather than in #apply_clone_source! so it is written for the
        # clone itself, not for the section that happens to host the Clone card. Never cleared by a
        # later ordinary save: "this configuration came from X" stays true until another clone
        # replaces it, which is exactly the question the Clone card's dropdown reopens on.
        @sla_policy.cloned_from_project_id = clone_source.project_id if clone_source
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
          apply_clone_source!(clone_source)
          replace_tracker_definitions!
        end
        notifications_skipped = !copy_notification_settings!(clone_source) if clone_source
      end
    rescue ActiveRecord::RecordInvalid => e
      flash[:error] = e.record.errors.full_messages.join(', ')
      return redirect_to settings_project_path(@project, tab: 'sla_policy', section: section)
    end

    flash[:notice] = l(:notice_successful_update)
    announce_clone_outcome(clone_source, notifications_skipped)
    if section == 'targets' && params[:recalculate] == '1'
      queue_recalculation
      flash[:notice] = "#{flash[:notice]} #{l(:notice_sla_recalculation_queued)}"
    end
    redirect_to settings_project_path(@project, tab: 'sla_policy', section: section)
  end

  # PATCH /projects/:project_id/sla_policy/target
  # Saves one tracker/priority/target cell. Target edits are intentionally independent from the
  # section form so a deadline is durable as soon as the user leaves the inline editor.
  def update_target
    @sla_policy = SlaPolicy.find_or_initialize_by(project_id: @project.id)
    tracker_id = params[:tracker_id].to_i
    priority_id = params[:priority_id].to_i
    target_type = params[:target_type].to_s
    return render json: { error: l(:error_sla_target_invalid) }, status: :unprocessable_entity unless
      @project.trackers.exists?(tracker_id) && IssuePriority.active.exists?(priority_id) &&
      SlaDefinition::TARGET_TYPES.include?(target_type)

    target = Sla::DirectDuration.parse(mode: params[:mode], value: params[:value], unit: params[:unit])
    ActiveRecord::Base.transaction do
      source = forking_from_inherited? ? inherited_seed_source : nil
      seed_scalars_from!(source) if source
      @sla_policy.coverage_hours = '24x7'
      @sla_policy.inherits_config = false
      @sla_policy.save!
      copy_configuration_from!(source) if source

      definition = @sla_policy.sla_definitions.find_or_initialize_by(
        tracker_id: tracker_id, priority_id: priority_id
      )
      definition.public_send("#{target_type}_seconds=", target[:seconds])
      definition.public_send("#{target_type}_best_effort=", target[:best_effort])
      definition.public_send("#{target_type}_unit=", target[:unit])
      definition_has_target?(definition) ? definition.save! : definition.destroy!
    end
    recalculation = queue_recalculation if params[:recalculate].to_s == '1'
    render json: target.merge(display: Sla::DirectDuration.label(target),
                              message: l(:text_sla_target_saved),
                              recalculation: recalculation_payload(recalculation))
  rescue Sla::DirectDuration::InvalidDuration, ActiveRecord::RecordInvalid => e
    render json: { error: e.message.presence || l(:error_sla_target_invalid) },
           status: :unprocessable_entity
  end

  # Copies all priority targets from one configured tracker into another tracker in this project.
  def clone_tracker
    @sla_policy = SlaPolicy.find_or_initialize_by(project_id: @project.id)
    source_id = params[:source_tracker_id].to_i
    target_id = params[:target_tracker_id].to_i
    project_tracker_ids = @project.trackers.ids
    inherited_source = forking_from_inherited? ? inherited_seed_source : nil
    config_source = inherited_source || @sla_policy
    source_definitions = config_source.sla_definitions.where(tracker_id: source_id)
    selected_ids = config_source.selected_tracker_ids_or_nil
    valid = source_id != target_id && project_tracker_ids.include?(source_id) &&
            project_tracker_ids.include?(target_id) && source_definitions&.exists? &&
            (selected_ids.nil? || (selected_ids.include?(source_id) && selected_ids.include?(target_id)))
    return render json: { error: l(:error_sla_tracker_clone_invalid) },
                  status: :unprocessable_entity unless valid

    ActiveRecord::Base.transaction do
      if inherited_source
        seed_scalars_from!(inherited_source)
        @sla_policy.coverage_hours = '24x7'
        @sla_policy.inherits_config = false
        @sla_policy.save!
        copy_configuration_from!(inherited_source)
      end
      source_definitions = @sla_policy.sla_definitions.where(tracker_id: source_id)
      @sla_policy.sla_definitions.where(tracker_id: target_id).delete_all
      source_definitions.find_each do |definition|
        attributes = definition.attributes.slice(*SlaDefinition::COPY_ATTRIBUTES)
        attributes['tracker_id'] = target_id
        @sla_policy.sla_definitions.create!(attributes)
      end
    end
    recalculation = queue_recalculation if params[:recalculate].to_s == '1'
    render json: { message: l(:text_sla_tracker_clone_saved),
                   recalculation: recalculation_payload(recalculation) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
  end

  # GET /projects/:project_id/sla_policy/recalculation_status
  # `before_action :authorize` applies the same project permission as every policy edit action.
  def recalculation_status
    state = SlaRecalculationState.find_by(project_id: @project.id)
    requested_token = params[:run_token].to_s
    state = nil if state && requested_token.present? && state.run_token != requested_token
    state = nil if state && requested_token.blank? && !state.active?

    render json: recalculation_status_payload(state)
  end

  # B3 — "Revert to inherited policy": deletes THIS project's own policy row (cascading to its
  # definitions/status mappings, per their `dependent: :destroy`) so the project falls back to
  # its nearest ancestor's policy. Never touches `sla_results` — the recalculation job UPDATES
  # those rows in place under the now-inherited policy, it never deletes the cache.
  def destroy
    sla_policy = SlaPolicy.find_by(project_id: @project.id)
    if sla_policy
      sla_policy.destroy!
      queue_recalculation
      flash[:notice] = l(:notice_sla_reverted_to_inherited)
    end
    redirect_to settings_project_path(@project, tab: 'sla_policy')
  end

  private

  def queue_recalculation
    state = Sla::RecalculationDispatcher.call(@project)
    flash[:sla_recalculation_token] = state.run_token
    state
  end

  def recalculation_payload(state)
    return nil unless state

    { run_token: state.run_token, status: state.status }
  end

  def recalculation_status_payload(state)
    return { status: 'idle', progress: 0 } unless state

    message = case state.status
              when 'queued'
                l(:text_sla_recalculation_waiting)
              when 'running'
                l(:text_sla_recalculation_running,
                  processed: state.processed_count, total: state.total_count)
              when 'completed'
                l(:text_sla_recalculation_completed, count: state.processed_count)
              else
                state.error_message.presence || l(:error_sla_recalculation_failed)
              end
    {
      run_token: state.run_token,
      status: state.status,
      processed: state.processed_count,
      total: state.total_count,
      progress: state.progress_percentage,
      message: message,
      updated_at: state.updated_at&.iso8601
    }
  end

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
    queue_recalculation
    flash[:notice] = l(:notice_successful_update)
  end

  # Drops back to "whatever the ancestor decides". Only ever deletes a lightweight row — a full
  # override is reverted through #destroy's "Revert to inherited policy" button, which carries its
  # own confirmation because it discards a whole configuration.
  def revert_to_inherited_enablement
    policy = SlaPolicy.find_by(project_id: @project.id)
    return flash[:notice] = l(:notice_successful_update) if policy.nil?

    policy.destroy!
    queue_recalculation
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

  # The clone source the user loaded and is now saving, or nil when this is an ordinary save.
  # Deliberately not memoised — see the note at its single call site in #update.
  def clone_source_policy
    return nil if params[:clone_source_id].blank?

    authorized_source_policy(params[:clone_source_id])
  end

  # The ancestor whose configuration this project inherits today — what a FORK seeds from. The
  # clone source is resolved separately (above) and takes priority in #update, so this no longer
  # has to consider it. nil for the first policy anywhere in the tree: there the form really is
  # blank and the DB defaults are right.
  def inherited_seed_source
    SlaPolicy.config_source_for(@project).last
  end

  # Scalars first, so the posted section's own fields (assigned after this) win.
  #
  # Without it, every scalar the posted section does not own falls back to the DB column default —
  # and for `enabled` that default is FALSE, an explicit "SLA off" that also stops inheritance
  # (SlaPolicy.effective_for). Saving, say, Measurement Rules on a project inheriting an ENABLED
  # policy would silently switch SLA off for a project whose screen showed it on.
  #
  # `enabled` on an EXISTING row is the one attribute that needs a decision, and it differs by
  # reason: a FORK must leave it alone, because a lightweight row's on/off is the project's own
  # (set through the tri-state control) and an ancestor's must not overwrite it — whereas a CLONE
  # copies it, because it is part of the policy the user chose and the General panel showed them
  # its state, switch included, before they saved.
  def seed_scalars_from!(source, clone: false)
    attributes = source.attributes.slice(*POLICY_ATTRIBUTES.map(&:to_s))
    attributes.delete('enabled') if !clone && !@sla_policy.new_record?
    @sla_policy.assign_attributes(attributes)
  end

  # A clone carries the source's NOTIFICATION setup too — the whole point of "clone the policy" is
  # that the target needs no further setup. Those settings live on a different model behind a
  # different permission, so they get their own gate: the user must hold
  # :manage_sla_notifications on BOTH projects.
  #
  # Requiring it on the SOURCE is the part that matters. The Google Chat webhook is effectively a
  # secret, and :edit_sla_policy on a project (which is all #authorized_source_policy demands) must
  # not be enough to extract it into a project the user does control.
  #
  # @return [Boolean] false only when the copy was REFUSED, so #update can say so. A source with no
  #   notification row at all is not a refusal — there is simply nothing to carry across.
  def copy_notification_settings!(clone_source)
    # Presence first, so a source with nothing configured is never reported as a permission
    # refusal — telling someone they lack a permission when nothing was lost sends them chasing
    # an access problem that isn't there.
    source_setting = SlaNotificationSetting.find_by(project_id: clone_source.project_id)
    return true if source_setting.nil?
    return false unless notifications_copyable?(clone_source.project)

    SlaNotificationSetting.copy_to!(@project, source_setting)
    true
  end

  def notifications_copyable?(source_project)
    source_project.present? &&
      User.current.allowed_to?(:manage_sla_notifications, source_project) &&
      User.current.allowed_to?(:manage_sla_notifications, @project)
  end

  # Say what the clone actually did. A clone rewrites every section, so confirming it by name is
  # worth a line — and a refused notification copy has to be stated rather than left as a panel
  # the user assumes came across with everything else.
  #
  # The project name is ESCAPED before it goes anywhere near the flash. Redmine renders flash
  # content as raw HTML (`content_tag('div', v.html_safe, ...)` in ApplicationHelper
  # #render_flash_messages) and `Project#name` is free text with no format validation, so an
  # unescaped name here is stored XSS: anyone who can rename a project the victim may clone from
  # gets script execution in the victim's session.
  def announce_clone_outcome(source, notifications_skipped)
    return if source.nil?

    name = ERB::Util.html_escape(source.project&.name)
    flash[:notice] = "#{flash[:notice]} #{l(:notice_sla_clone_applied, project: name)}"
    return unless notifications_skipped

    flash[:warning] = l(:warning_sla_clone_notifications_skipped, project: name)
  end

  # Mirrors #build_clone_prefill for the Notifications panel, so a clone load SHOWS the settings it
  # is about to write. Returns nil when the copy would be refused, which leaves the panel exactly
  # as it was: the form must never preview values the save will not write.
  def build_clone_notification_prefill(source_project_id)
    source = authorized_source_policy(source_project_id)
    return nil unless source && notifications_copyable?(source.project)

    SlaNotificationSetting.prefill_for(
      @project, SlaNotificationSetting.find_by(project_id: source.project_id)
    )
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
    copy_tracker_selection_from!(source)
    return unless definitions

    @sla_policy.sla_definitions.delete_all
    copy_definitions_from!(source)
  end

  # The source's tracker selection, restricted to trackers THIS project has enabled — a copied
  # reference to a tracker the project cannot use would select a table it can never render. Skipped
  # when the source has no saved selection (nil), so a clone from an older policy leaves this row
  # deriving its tables from the definitions rather than asserting an empty picker.
  #
  # A `targets` save then overwrites this with the posted picker (#replace_tracker_definitions!
  # runs after), which is right: what the user reviewed on screen wins over what was copied.
  def copy_tracker_selection_from!(source)
    source_ids = source.selected_tracker_ids_or_nil
    return if source_ids.nil?

    @sla_policy.update!(selected_tracker_ids: source_ids & @project.trackers.ids)
  end

  # Shared by the fork above and Step 4.7's clone: the source's definitions, restricted to trackers
  # this project has enabled.
  def copy_definitions_from!(source)
    source.sla_definitions.where(tracker_id: @project.trackers.ids)
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
  # then override the copied ones. Scalars and status mappings are copied by #update's shared
  # clone/fork path, so this only owns the definitions.
  def apply_clone_source!(source)
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

    # Persist the picker itself, not just what it produced. The displayed set used to be derived
    # from the definitions alone, so a tracker added and saved with every target still on
    # "not tracked" wrote nothing (an all-blank row creates no record, by design) and was gone by
    # the time the redirect landed. Written even when the list is empty — [] is a real answer here,
    # distinct from the nil that means "this row predates the column" (see migration 009).
    @sla_policy.update!(selected_tracker_ids: tracker_ids)
    return if tracker_ids.empty? || params.dig(:definitions, :rows).blank?

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

    rows.each do |priority_id, targets|
      priority_id = priority_id.to_i
      next unless allowed_priority_ids.include?(priority_id)

      attributes = definition_targets(targets, previous[priority_id])
      next if attributes.empty?

      @sla_policy.sla_definitions.create!(
        { tracker_id: tracker_id, priority_id: priority_id }.merge(attributes)
      )
    end
  end

  def definition_targets(targets, _previous_definition)
    SlaDefinition::TARGET_TYPES.each_with_object({}) do |target_type, attributes|
      raw = targets[target_type].presence
      next unless raw

      if raw == SlaPoliciesHelper::SLA_BEST_EFFORT_VALUE
        attributes["#{target_type}_seconds"] = nil
        attributes["#{target_type}_best_effort"] = true
        attributes["#{target_type}_unit"] = nil
      else
        seconds = raw.to_i
        if seconds.positive? && seconds <= Sla::DirectDuration::MAX_SECONDS
          attributes["#{target_type}_seconds"] = seconds
          attributes["#{target_type}_best_effort"] = false
          attributes["#{target_type}_unit"] = 'hours'
        end
      end
    end
  end

  def definition_has_target?(definition)
    SlaDefinition::TARGET_TYPES.any? do |type|
      definition.public_send("#{type}_seconds").present? || definition.best_effort?(type)
    end
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
