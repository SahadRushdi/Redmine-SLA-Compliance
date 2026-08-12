require_relative '../test_helper'

# Phase 4 save path: persistence as IDs, diff-replace semantics, per-tracker definition
# replacement, clone, recalc enqueue, and permission/module gating.
class SlaPoliciesControllerTest < ActionController::TestCase
  include ActiveJob::TestHelper

  fixtures :projects, :projects_trackers, :trackers, :issue_statuses, :workflows,
           :enumerations, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules

  setup do
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    @role = Role.find(1) # Manager — user 2 (jsmith) holds it on project 1
    @role.add_permission!(:edit_sla_policy)
    @request.session[:user_id] = 2

    @status_ids = @project.rolled_up_statuses.map(&:id)
    @priorities = IssuePriority.active.to_a
    @trackers = @project.trackers.to_a
    assert @status_ids.size >= 2, 'fixtures must provide at least two project statuses'
    assert @trackers.size >= 2, 'fixtures must provide at least two project trackers'

    duration = Struct.new(:seconds)
    @opt_1h = duration.new(3600)
    @opt_4h = duration.new(14_400)
    @opt_2h = duration.new(7200)
    @opt_1d = duration.new(86_400)
  end

  # The tab saves one section at a time (SlaPoliciesHelper::SECTIONS): each section's form posts
  # only its own fields plus the `section` key that tells #update which slice it may rewrite.
  # Tests therefore post through the section that actually owns the fields under test — and a
  # scenario spanning two sections posts twice, exactly as the UI does.
  def general_params(overrides = {})
    { project_id: @project.id, tab: 'sla_policy', section: 'general',
      sla_policy: { enabled: '1', coverage_hours: '24x7' } }.deep_merge(overrides)
  end

  def measurement_params(overrides = {})
    { project_id: @project.id, tab: 'sla_policy', section: 'measurement',
      sla_policy: { first_response_rule: 'first_comment',
                    at_risk_threshold: '75' } }.deep_merge(overrides)
  end

  def targets_params(overrides = {})
    { project_id: @project.id, tab: 'sla_policy', section: 'targets' }.deep_merge(overrides)
  end

  def exclusions_params(overrides = {})
    { project_id: @project.id, tab: 'sla_policy', section: 'exclusions',
      sla_policy: { pause_enabled: '1' } }.deep_merge(overrides)
  end

  def policy
    SlaPolicy.find_by(project_id: @project.id)
  end

  # --- gating -------------------------------------------------------------------------------

  test "update is forbidden without edit_sla_policy" do
    @role.remove_permission!(:edit_sla_policy)
    put :update, params: general_params
    assert_response :forbidden
    assert_nil policy
  end

  test "manage_sla_notifications alone does not grant the policy actions" do
    @role.remove_permission!(:edit_sla_policy)
    @role.add_permission!(:manage_sla_notifications)
    put :update, params: general_params
    assert_response :forbidden
  end

  test "update is forbidden when the module is disabled" do
    @project.disable_module!(:sla_compliance)
    put :update, params: general_params
    assert_response :forbidden
  end

  # --- Step 5.1: the SLA access roles ----------------------------------------------------------
  # rhill (user 4) holds no role and no membership, so nothing but the grant below can let them
  # through. The role itself ticks NO permissions — being named in the plugin settings is the
  # whole of what makes it work.

  test "a member holding an SLA access role can save the policy" do
    role = Role.create!(name: 'SLA Access Test Role', permissions: [])
    Member.create!(principal: User.find(4), project: @project, roles: [role])
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => [role.id.to_s] }
    @request.session[:user_id] = 4

    put :update, params: general_params

    assert_redirected_to settings_project_path(@project, tab: 'sla_policy', section: 'general')
    assert policy.present?, 'a granted member must be able to save the policy'
  ensure
    Setting.plugin_redmine_sla_compliance = {}
  end

  test "holding a role that is not an SLA access role cannot save the policy" do
    role = Role.create!(name: 'SLA Unlisted Test Role', permissions: [])
    Member.create!(principal: User.find(4), project: @project, roles: [role])
    @request.session[:user_id] = 4

    put :update, params: general_params

    assert_response :forbidden
    assert_nil policy
  ensure
    Setting.plugin_redmine_sla_compliance = {}
  end

  # --- scalars (4.2 / 4.3 / 4.8 defaults) ---------------------------------------------------

  test "each section persists its own scalars and redirects back to itself" do
    put :update, params: general_params
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy', section: 'general')
    put :update, params: measurement_params
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy', section: 'measurement')
    put :update, params: exclusions_params
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy', section: 'exclusions')

    saved = policy
    assert saved.enabled?
    assert_equal '24x7', saved.coverage_hours
    assert_equal 'first_comment', saved.first_response_rule
    assert_equal 75, saved.at_risk_threshold
    assert saved.pause_enabled?
  end

  # --- creating the row from a section that doesn't own every scalar -------------------------
  #
  # Regression (B3, second time around): a section form posts only ITS OWN scalars, so a row
  # first written from any section other than General used to take `enabled`'s column default of
  # FALSE — and a disabled policy is an explicit "SLA off" that also stops inheritance. The
  # damaging path is Override: the form is prefilled from an ENABLED ancestor and shows the
  # toggle ON, but saving SLA Targets before General persisted it OFF.

  def grant_child_access(child)
    child.enable_module!(:sla_compliance)
    member = Member.find_or_initialize_by(user_id: 2, project_id: child.id)
    member.role_ids = (member.role_ids + [@role.id]).uniq
    member.save!
  end

  test "overriding an inherited policy from a non-General section keeps SLA enabled" do
    child = Project.find(5) # parent = @project (1)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true, at_risk_threshold: 90,
                      first_response_rule: 'either')
    assert SlaPolicy.effective_for(child)&.enabled?, 'precondition: child inherits an ENABLED policy'

    # Override pressed (prefills from the ancestor), then SLA Targets saved before General.
    put :update, params: { project_id: child.id, tab: 'sla_policy', section: 'targets',
                           clone_source_id: @project.id.to_s,
                           definitions: { tracker_ids: [child.trackers.first.id.to_s],
                                          rows: { child.trackers.first.id.to_s => { @priorities.first.id.to_s =>
                                                      { response: @opt_1h.seconds.to_s } } } } }

    own = SlaPolicy.find_by(project_id: child.id)
    assert own.present?, 'the override must create the child its own policy'
    assert own.enabled?, 'the override must not silently switch SLA off for the child project'
    assert SlaPolicy.effective_for(child).present?,
           'SLA must still be in effect for the child after overriding an enabled policy'
    # The rest of the ancestor's scalars come along too, matching what the prefilled form showed.
    assert_equal 90, own.at_risk_threshold
    assert_equal 'either', own.first_response_rule
  end

  # The inheriting project now edits a form pre-filled from its ancestor, so the FIRST save of any
  # section is a fork: the whole inherited configuration has to come across, not just the section
  # that was posted. Without this, saving General alone would leave the child with a row holding no
  # milestone statuses and no targets — a policy that measures nothing — for a project that was
  # fully covered a moment before.
  test "the first save of any section forks the whole inherited configuration" do
    child = Project.find(5)
    grant_child_access(child)
    parent = SlaPolicy.create!(project_id: @project.id, enabled: true, at_risk_threshold: 90)
    status_id = child.rolled_up_statuses.first.id
    parent.sla_status_mappings.create!(role: 'resolved', status_id: status_id)
    parent.sla_definitions.create!(tracker_id: child.trackers.first.id,
                                   priority_id: @priorities.first.id, response_seconds: 3600)

    # General posts only coverage/enabled — nothing about statuses or targets.
    put :update, params: { project_id: child.id, tab: 'sla_policy', section: 'general',
                           sla_policy: { enabled: '1', coverage_hours: '24x7' } }

    own = SlaPolicy.find_by(project_id: child.id)
    assert_equal [status_id], own.status_ids_for(:resolved)
    assert_equal 3600, own.sla_definitions.find_by(tracker_id: child.trackers.first.id,
                                                   priority_id: @priorities.first.id)
                          .response_seconds
    assert_equal 90, own.at_risk_threshold, "the ancestor's scalars come across too"
  end

  # Same fork, starting from a LIGHTWEIGHT row: the row already exists (so it is not a new record)
  # but owns no configuration, and its own on/off decision must survive the fork rather than being
  # overwritten by the ancestor's.
  test "forking from a lightweight row copies the configuration and keeps its own decision" do
    child = Project.find(5)
    grant_child_access(child)
    parent = SlaPolicy.create!(project_id: @project.id, enabled: true)
    status_id = child.rolled_up_statuses.first.id
    parent.sla_status_mappings.create!(role: 'resolved', status_id: status_id)
    SlaPolicy.create!(project_id: child.id, enabled: false, inherits_config: true)

    # Exclusions owns the `pause` role only — every other role has to arrive by inheritance.
    put :update, params: { project_id: child.id, tab: 'sla_policy', section: 'exclusions',
                           sla_policy: { pause_enabled: '1' } }

    own = SlaPolicy.find_by(project_id: child.id)
    assert_not own.inherits_config?, 'saving configuration makes the row self-defining'
    assert_not own.enabled?, "the lightweight row's own SLA-off decision must survive the fork"
    assert_equal [status_id], own.status_ids_for(:resolved), 'the inherited role comes across'
  end

  test "cloning another project's policy from a non-General section keeps its scalars" do
    build_clone_source # project 2, enabled, at_risk_threshold 90, rule 'either'

    put :update, params: targets_params(
      { clone_source_id: '2',
        definitions: { tracker_ids: [@trackers.first.id.to_s], rows: { @trackers.first.id.to_s => {} } } }
    )

    saved = policy
    assert saved.enabled?, 'a clone load showed the source as enabled; saving must persist that'
    assert_equal 90, saved.at_risk_threshold
    assert_equal 'either', saved.first_response_rule
  end

  test "the first policy in the tree still starts disabled when no source was loaded" do
    # Nothing to inherit and nothing cloned: the blank form shows the toggle OFF, so saving any
    # section must agree with it rather than invent an enabled policy.
    put :update, params: measurement_params
    refute policy.enabled?
  end

  test "saving a section never resets scalars owned by another section" do
    put :update, params: general_params(sla_policy: { enabled: '1', coverage_hours: '24x7' })
    put :update, params: measurement_params(sla_policy: { at_risk_threshold: '55',
                                                          first_response_rule: 'either' })
    put :update, params: exclusions_params(sla_policy: { pause_enabled: '0' })

    saved = policy
    assert saved.enabled?, 'General\'s toggle must survive later saves of other sections'
    assert_equal 55, saved.at_risk_threshold
    assert_equal 'either', saved.first_response_rule
    refute saved.pause_enabled?
  end

  # --- section/role wiring invariant ----------------------------------------------------------
  #
  # replace_status_mappings! only ever touches roles the posted section claims, so a role missing
  # from SECTION_STATUS_ROLES is unreachable: its chips would post, the save would report success,
  # and the selection would silently never persist. Pin the mapping rather than trusting a comment.
  test "every status role is owned by exactly one section" do
    owned = SlaPoliciesController::SECTION_STATUS_ROLES.values.flatten

    assert_equal SlaStatusMapping::ROLES.sort, owned.sort,
                 'every SlaStatusMapping role must be claimed by exactly one section, and no ' \
                 'section may claim a role that does not exist'
    assert_equal owned.uniq, owned, 'a role claimed by two sections would be cleared by either save'
    # Membership, not order — SECTIONS is also the sidebar's running order and is free to change.
    assert_empty SlaPoliciesController::POLICY_SECTIONS -
                 SlaPoliciesHelper::SECTIONS.map { |section| section[:key] },
                 'every savable section must also be offered in the sidebar'
    assert (SlaPoliciesController::SECTION_STATUS_ROLES.keys - SlaPoliciesController::POLICY_SECTIONS).empty?,
           'a role owned by an unknown section could never be posted'
  end

  test "business hours coverage persists with its calendar" do
    calendar = SlaBusinessCalendar.create!(name: 'Std', working_days: [1, 2, 3, 4, 5],
                                           work_start_time: '09:00', work_end_time: '17:00')
    put :update, params: general_params(
      sla_policy: { coverage_hours: 'business_hours', business_calendar_id: calendar.id.to_s }
    )
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy', section: 'general')
    assert_equal calendar.id, policy.business_calendar_id
  end

  test "business hours without a calendar fails atomically" do
    put :update, params: general_params(sla_policy: { coverage_hours: 'business_hours' })
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy', section: 'general')
    assert flash[:error].present?
    assert_nil policy
  end

  test "a rejected section save writes none of that section's side effects" do
    # The section's scalars and its status rows share one transaction: an invalid threshold must
    # take the milestone statuses posted alongside it down with it.
    put :update, params: measurement_params(
      { sla_policy: { at_risk_threshold: '0' },
        status_mappings: { created: [@status_ids.first.to_s] } }
    )

    assert flash[:error].present?
    assert_nil policy
    assert_equal 0, SlaStatusMapping.count
  end

  # --- status mappings (4.3 / 4.5) ----------------------------------------------------------

  test "status selections persist as ID rows per role" do
    created = @status_ids.first(2)
    resolved = [@status_ids.last]
    put :update, params: measurement_params(
      status_mappings: { created: created.map(&:to_s), resolved: resolved.map(&:to_s) }
    )
    put :update, params: exclusions_params(
      status_mappings: { pause: resolved.map(&:to_s) }
    )
    saved = policy
    assert_equal created.sort, saved.status_ids_for(:created).sort
    assert_equal resolved, saved.status_ids_for(:resolved)
    assert_equal resolved, saved.status_ids_for(:pause)
    assert_equal [], saved.status_ids_for(:work_started)
  end

  test "resubmitting different statuses diff-replaces, and omitting a role clears it" do
    put :update, params: measurement_params(
      status_mappings: { created: @status_ids.first(2).map(&:to_s),
                         resolved: [@status_ids.last.to_s] }
    )
    put :update, params: measurement_params(
      status_mappings: { created: [@status_ids[1].to_s] } # resolved omitted -> cleared
    )
    saved = policy
    assert_equal [@status_ids[1]], saved.status_ids_for(:created)
    assert_equal [], saved.status_ids_for(:resolved)
  end

  # The whole point of the per-section save: "omitting a role clears it" must apply ONLY within
  # the section that owns that role. Before sectioning, one Save owned every field, so saving the
  # page from any state rewrote everything at once; now a Measurement Rules save posts no pause
  # statuses and must leave the Exclusions section's selection exactly as it was.
  test "saving one section leaves another section's status roles untouched" do
    put :update, params: exclusions_params(
      status_mappings: { pause: [@status_ids.last.to_s] }
    )
    put :update, params: measurement_params(
      status_mappings: { created: [@status_ids.first.to_s] }
    )

    saved = policy
    assert_equal [@status_ids.last], saved.status_ids_for(:pause),
                 'a Measurement Rules save must not clear the Exclusions pause statuses'
    assert_equal [@status_ids.first], saved.status_ids_for(:created)
  end

  test "a forged section value falls back to the section that owns nothing" do
    put :update, params: exclusions_params(
      status_mappings: { pause: [@status_ids.last.to_s] }
    )
    put :update, params: exclusions_params(
      { section: 'everything', status_mappings: { created: [@status_ids.first.to_s] } }
    )

    saved = policy
    assert_equal [@status_ids.last], saved.status_ids_for(:pause)
    assert_equal [], saved.status_ids_for(:created),
                 'an unrecognised section must write no status rows at all'
  end

  # Phase-4-level regression (C): the engine-level "empty pause list = no pause" guard is already
  # tested in isolation at Phase 2 (Sla::PauseCalculator), but nothing previously proved the UI
  # form's save path actually WIRES an empty selection through to that behavior end-to-end.
  test "an empty pause list saved via the form round-trips into no pause subtraction at the engine level" do
    work_status = @status_ids.second
    put :update, params: general_params # SLA tracking is switched on in General
    put :update, params: measurement_params(
      status_mappings: { created: [@status_ids.first.to_s] }
    )
    put :update, params: exclusions_params(status_mappings: {}) # pause intentionally left empty
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { @priorities.first.id.to_s => { response: @opt_1h.seconds.to_s } } } }
    )
    saved = policy
    assert_equal [], saved.status_ids_for(:pause), 'pause selection must round-trip to empty'

    base = Time.zone.local(2026, 6, 1, 9, 0, 0)
    issue = Issue.new(project_id: @project.id, tracker_id: @trackers.first.id, author_id: 2,
                      priority_id: @priorities.first.id, status_id: @status_ids.first,
                      subject: 'pause round-trip')
    issue.save!(validate: false)
    issue.update_column(:created_on, base)

    # A status change into a status that WOULD have paused the clock if pause were configured.
    journal = Journal.new(journalized: issue, user: User.find(2), created_on: base + 10.minutes)
    journal.details << JournalDetail.new(property: 'attr', prop_key: 'status_id',
                                         old_value: @status_ids.first.to_s, value: work_status.to_s)
    journal.save!
    issue.update_column(:status_id, work_status)

    result = Sla::IssueEvaluator.new(issue.reload, now: base + 50.minutes).call
    assert_equal 3000, result.response_seconds,
                 'no pause status is configured, so the full 50 minutes must count, unreduced'
  end

  test "statuses foreign to the project are rejected" do
    foreign = IssueStatus.create!(name: 'Not In Workflow')
    assert_not_includes @status_ids, foreign.id
    put :update, params: measurement_params(
      status_mappings: { created: [foreign.id.to_s, @status_ids.first.to_s] }
    )
    assert_equal [@status_ids.first], policy.status_ids_for(:created)
  end

  # --- definitions (4.4) ---------------------------------------------------------------------

  test "targets persist per tracker and priority as seconds from the lookup" do
    priority = @priorities.first
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { priority.id.to_s => { response: '3600', workaround: '7200',
                                                     resolution: '86400' } } } }
    )
    definition = policy.sla_definitions.find_by(tracker_id: @trackers.first.id,
                                                priority_id: priority.id)
    assert definition
    assert_equal 3600, definition.response_seconds
    assert_equal 7200, definition.workaround_seconds
    assert_equal 86_400, definition.resolution_seconds
  end

  test "the Update Frequency target persists like the other three, from the same lookup" do
    cadence = SlaTargetOption.create!(target_type: 'update_frequency', code: '8h',
                                      label: 'Every 8 hours', seconds: 28_800)
    priority = @priorities.first
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s =>
                               { priority.id.to_s => { response: '3600',
                                                       update_frequency: cadence.seconds.to_s } } } }
    )
    definition = policy.sla_definitions.find_by(tracker_id: @trackers.first.id,
                                                priority_id: priority.id)
    assert_equal 28_800, definition.update_frequency_seconds
    assert_equal 3600, definition.response_seconds
  end

  test "an Update Frequency value not in the lookup is rejected, like every other target" do
    priority = @priorities.first
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s =>
                               { priority.id.to_s => { response: '3600',
                                                       update_frequency: '61' } } } }
    )
    definition = policy.sla_definitions.find_by(tracker_id: @trackers.first.id,
                                                priority_id: priority.id)
    assert_nil definition.update_frequency_seconds, 'a forged duration is not written'
    assert_equal 3600, definition.response_seconds, 'the rest of the row still saves'
  end

  # --- Step 6.2a: the Stale threshold, per project and clearable --------------------------------

  test "the stale threshold saves with the rest of the Measurement Rules section" do
    put :update, params: measurement_params(sla_policy: { stale_threshold_days: '2' })

    assert_equal 2, policy.stale_threshold_days
  end

  test "clearing the stale threshold stores nothing, so the project inherits again" do
    put :update, params: measurement_params(sla_policy: { stale_threshold_days: '2' })
    assert_equal 2, policy.stale_threshold_days

    put :update, params: measurement_params(sla_policy: { stale_threshold_days: '' })

    assert_nil policy.reload.stale_threshold_days, 'an empty field must clear the override'
  end

  test "a nonsensical stale threshold is refused rather than stored" do
    put :update, params: measurement_params(sla_policy: { stale_threshold_days: '0' })

    assert_nil SlaPolicy.find_by(project_id: @project.id)&.stale_threshold_days
    assert flash[:error].present?, 'the save must report why it did not take'
  end

  test "saving another section leaves the stale threshold alone" do
    put :update, params: measurement_params(sla_policy: { stale_threshold_days: '2' })

    put :update, params: general_params

    assert_equal 2, policy.reload.stale_threshold_days
  end

  test "saving replaces only the posted tracker's definitions" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    priority = @priorities.first
    keep = saved_policy.sla_definitions.create!(tracker_id: @trackers.first.id,
                                                priority_id: priority.id,
                                                response_seconds: 3600)
    saved_policy.sla_definitions.create!(tracker_id: @trackers.second.id,
                                         priority_id: priority.id, response_seconds: 3600)

    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.second.id.to_s],
                     rows: { @trackers.second.id.to_s => { priority.id.to_s => { response: '14400' } } } }
    )

    assert_equal 3600, keep.reload.response_seconds # tracker 1 untouched
    replaced = policy.sla_definitions.find_by(tracker_id: @trackers.second.id,
                                              priority_id: priority.id)
    assert_equal 14_400, replaced.response_seconds
  end

  test "several trackers posted together are all written in one save" do
    priority = @priorities.first
    first, second = @trackers.first, @trackers.second

    put :update, params: targets_params(
      definitions: { tracker_ids: [first.id.to_s, second.id.to_s],
                     rows: { first.id.to_s  => { priority.id.to_s => { response: '3600' } },
                             second.id.to_s => { priority.id.to_s => { response: '14400' } } } }
    )

    assert_equal 3600, policy.sla_definitions
                             .find_by(tracker_id: first.id, priority_id: priority.id)
                             .response_seconds
    assert_equal 14_400, policy.sla_definitions
                               .find_by(tracker_id: second.id, priority_id: priority.id)
                               .response_seconds
  end

  # --- The tracker picker's own selection is saved (migration 009) -----------------------------
  #
  # Regression: the displayed set was DERIVED from the definitions, so a tracker added and saved
  # with every target still on "not tracked" wrote no definition (an all-blank row creates no
  # record, by design), left no trace anywhere, and had disappeared by the time the redirect
  # landed — the user's "I add new trackers and save, and they are missing".

  test "a tracker selected with no targets set is still remembered after saving" do
    empty = @trackers.second

    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s, empty.id.to_s],
                     rows: { @trackers.first.id.to_s => { @priorities.first.id.to_s => { response: '3600' } },
                             empty.id.to_s => { @priorities.first.id.to_s => { response: '' } } } }
    )

    saved = policy
    assert_empty saved.sla_definitions.where(tracker_id: empty.id),
                 'precondition: an all-blank row still creates no definition'
    assert_includes saved.selected_tracker_ids_or_nil, empty.id,
                    'the picker itself must be saved, or a targetless tracker vanishes on reload'
  end

  test "the saved tracker selection remains authoritative when removed trackers have targets" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    with_targets = @trackers.second
    saved_policy.sla_definitions.create!(tracker_id: with_targets.id,
                                         priority_id: @priorities.first.id,
                                         response_seconds: 3600)
    saved_policy.update!(selected_tracker_ids: @trackers.map(&:id))

    # Submit exactly what the browser posts after removing the second tracker and pressing Save.
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s] }
    )
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy', section: 'targets')
    saved_policy.reload
    assert_equal [@trackers.first.id], saved_policy.selected_tracker_ids_or_nil

    # Called with no request params: a `tracker_id` in the request legitimately overrides the saved
    # set (that is how the AJAX per-table re-render asks for one tracker), which is a different
    # branch from the one under test here.
    displayed = @controller.view_context.send(:sla_selected_trackers, @project, saved_policy)

    assert_equal [@trackers.first], displayed
    assert saved_policy.sla_definitions.where(tracker_id: with_targets.id).exists?,
           'the hidden target values remain available if the tracker is re-added'
  end

  test "a policy saved before the column existed still shows its definition-derived trackers" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    saved_policy.sla_definitions.create!(tracker_id: @trackers.second.id,
                                         priority_id: @priorities.first.id,
                                         response_seconds: 3600)
    assert_nil saved_policy.selected_tracker_ids_or_nil, 'precondition: never saved a selection'

    displayed = @controller.view_context.send(:sla_selected_trackers, @project, saved_policy)

    assert_equal [@trackers.second], displayed
  end

  # The picker chooses which trackers are on screen and therefore editable — not which trackers
  # have an SLA. Hiding one must never be a silent delete; clearing targets is done by setting
  # every one of that tracker's rows to "not tracked".
  test "a tracker left out of the submit keeps its stored targets" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    priority = @priorities.first
    untouched = saved_policy.sla_definitions.create!(tracker_id: @trackers.second.id,
                                                     priority_id: priority.id,
                                                     response_seconds: 3600)

    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { priority.id.to_s => { response: '14400' } } } }
    )

    assert_equal 3600, untouched.reload.response_seconds
  end

  # Rows posted for a tracker the submit did not select are ignored — the tracker_ids list is the
  # authority, so a stale or forged rows entry cannot write outside what the form showed.
  test "rows for an unselected tracker are ignored" do
    priority = @priorities.first

    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s  => { priority.id.to_s => { response: '3600' } },
                             @trackers.second.id.to_s => { priority.id.to_s => { response: '14400' } } } }
    )

    assert_nil policy.sla_definitions.find_by(tracker_id: @trackers.second.id)
  end

  test "a priority with every target blank gets no definition row" do
    priority = @priorities.first
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { priority.id.to_s => { response: '', workaround: '',
                                                     resolution: '' } } } }
    )
    assert_equal 0, policy.sla_definitions.count
  end

  test "seconds not in the lookup are rejected" do
    priority = @priorities.first
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { priority.id.to_s => { response: '12345' } } } }
    )
    assert_equal 0, policy.sla_definitions.count
  end

  # --- Best Effort + basis (B4) --------------------------------------------------------------

  test "posting 'best_effort' persists a Best Effort target with no seconds value" do
    SlaTargetOption.create!(target_type: 'resolution', code: 'be', label: 'Best Effort',
                            best_effort: true)
    priority = @priorities.first

    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { priority.id.to_s => { resolution: 'best_effort' } } } }
    )

    definition = policy.sla_definitions.find_by(tracker_id: @trackers.first.id, priority_id: priority.id)
    assert definition.resolution_best_effort?
    assert_nil definition.resolution_seconds
  end

  test "posting 'best_effort' is rejected when no Best Effort option is configured for that type" do
    priority = @priorities.first

    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { priority.id.to_s => { resolution: 'best_effort' } } } }
    )

    assert_equal 0, policy.sla_definitions.count
  end

  test "a business-basis target under 24x7x365 coverage fails the save atomically" do
    SlaTargetOption.create!(target_type: 'resolution', code: '1bd', label: '1 Business Day',
                            seconds: 28_800, basis: 'business')
    priority = @priorities.first

    # Coverage is set in General, the target in SLA Targets — two saves, as the UI does it.
    put :update, params: general_params(sla_policy: { coverage_hours: '24x7' })
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { priority.id.to_s => { resolution: '28800' } } } }
    )

    assert flash[:error].present?
    assert_equal 0, policy&.sla_definitions&.count.to_i
  end

  test "a business-basis target is accepted under Business Hours coverage" do
    calendar = SlaBusinessCalendar.create!(name: 'Std', working_days: [1, 2, 3, 4, 5],
                                           work_start_time: '09:00', work_end_time: '17:00')
    SlaTargetOption.create!(target_type: 'resolution', code: '1bd', label: '1 Business Day',
                            seconds: 28_800, basis: 'business')
    priority = @priorities.first

    put :update, params: general_params(
      sla_policy: { coverage_hours: 'business_hours', business_calendar_id: calendar.id.to_s }
    )
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { priority.id.to_s => { resolution: '28800' } } } }
    )

    refute flash[:error].present?
    definition = policy.sla_definitions.find_by(tracker_id: @trackers.first.id, priority_id: priority.id)
    assert_equal 28_800, definition.resolution_seconds
  end

  test "a priority named None can be assigned SLA targets" do
    none = IssuePriority.create!(name: 'None', type: 'IssuePriority', position: 99)
    # Simulate a stale setting saved by an older plugin version.
    Setting.plugin_redmine_sla_compliance = { 'unclassified_priority_id' => none.id.to_s }

    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { none.id.to_s => { response: @opt_1h.seconds.to_s } } } }
    )

    definition = policy.sla_definitions.find_by!(priority_id: none.id)
    assert_equal @opt_1h.seconds, definition.response_seconds
  ensure
    Setting.plugin_redmine_sla_compliance = {}
  end

  test "a previously saved value survives even after the lookup changed" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    priority = @priorities.first
    saved_policy.sla_definitions.create!(tracker_id: @trackers.first.id,
                                         priority_id: priority.id,
                                         response_seconds: 99_999) # no longer in the lookup

    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s],
                     rows: { @trackers.first.id.to_s => { priority.id.to_s => { response: '99999' } } } }
    )
    definition = policy.sla_definitions.find_by(tracker_id: @trackers.first.id,
                                                priority_id: priority.id)
    assert_equal 99_999, definition.response_seconds
  end

  # --- clone (4.7) ----------------------------------------------------------------------------

  def build_clone_source
    source_project = Project.find(2)
    source_project.enable_module!(:sla_compliance)
    member = Member.find_or_initialize_by(user_id: 2, project_id: source_project.id)
    member.role_ids = (member.role_ids + [@role.id]).uniq
    member.save!
    source = SlaPolicy.create!(project_id: source_project.id, enabled: true,
                               first_response_rule: 'either', at_risk_threshold: 90)
    priority = @priorities.first
    source.sla_definitions.create!(tracker_id: @trackers.first.id, priority_id: priority.id,
                                   response_seconds: 3600)
    source.sla_definitions.create!(tracker_id: @trackers.second.id, priority_id: priority.id,
                                   response_seconds: 14_400)
    source
  end

  test "saving with clone_source_id copies all source definitions then applies the posted tracker" do
    build_clone_source
    priority = @priorities.first

    put :update, params: measurement_params(
      sla_policy: { at_risk_threshold: '90', first_response_rule: 'either' }
    )
    put :update, params: targets_params(
      { clone_source_id: '2',
        definitions: { tracker_ids: [@trackers.second.id.to_s],
                       rows: { @trackers.second.id.to_s => { priority.id.to_s => { response: '3600' } } } } }
    )

    saved = policy
    assert_equal 90, saved.at_risk_threshold
    copied = saved.sla_definitions.find_by(tracker_id: @trackers.first.id,
                                           priority_id: priority.id)
    assert_equal 3600, copied.response_seconds, 'non-visible tracker copied from source'
    overridden = saved.sla_definitions.find_by(tracker_id: @trackers.second.id,
                                               priority_id: priority.id)
    assert_equal 3600, overridden.response_seconds, 'posted tracker overrides the copy'
  end

  # --- clone provenance (migration 009) --------------------------------------------------------
  #
  # Regression: nothing recorded WHICH project a policy was cloned from, so the Clone card reopened
  # on "— Select a project —" and where a whole configuration came from was knowable only to
  # whoever ran the clone, at the moment they ran it.

  test "saving a clone records the project it was cloned from" do
    build_clone_source

    put :update, params: targets_params(
      { clone_source_id: '2',
        definitions: { tracker_ids: [@trackers.first.id.to_s], rows: { @trackers.first.id.to_s => {} } } }
    )

    assert_equal 2, policy.cloned_from_project_id
  end

  test "an ordinary later save keeps the recorded clone source" do
    build_clone_source
    put :update, params: targets_params(
      { clone_source_id: '2',
        definitions: { tracker_ids: [@trackers.first.id.to_s], rows: { @trackers.first.id.to_s => {} } } }
    )

    # No clone_source_id this time — the user is just editing. Provenance is history, not a binding:
    # it stays true until another clone replaces it.
    put :update, params: targets_params(
      definitions: { tracker_ids: [@trackers.first.id.to_s], rows: { @trackers.first.id.to_s => {} } }
    )

    assert_equal 2, policy.cloned_from_project_id
  end

  test "the clone dropdown reopens preselected on the recorded source" do
    build_clone_source
    put :update, params: targets_params(
      { clone_source_id: '2',
        definitions: { tracker_ids: [@trackers.first.id.to_s], rows: { @trackers.first.id.to_s => {} } } }
    )

    sources = @controller.view_context.send(:sla_clone_source_projects, @project)

    assert_equal Project.find(2),
                 @controller.view_context.send(:sla_cloned_from_project, policy, sources)
  end

  # It is deliberately a plain id, not a foreign key, so it survives the source changing. A source
  # the user can no longer pick is not an option on the page, so it must resolve to no selection
  # rather than to an id with no matching <option>.
  test "a recorded clone source the user can no longer pick resolves to no selection" do
    build_clone_source
    put :update, params: targets_params(
      { clone_source_id: '2',
        definitions: { tracker_ids: [@trackers.first.id.to_s], rows: { @trackers.first.id.to_s => {} } } }
    )
    SlaPolicy.find_by(project_id: 2).destroy! # source has no policy to clone any more

    sources = @controller.view_context.send(:sla_clone_source_projects, @project)

    assert_equal 2, policy.cloned_from_project_id, 'the record itself survives'
    assert_nil @controller.view_context.send(:sla_cloned_from_project, policy, sources)
  end

  # A clone means the WHOLE policy, not the section hosting the button. This used to hold only for
  # a project with no policy of its own (which took the inherited-fork path); a project that
  # already had one copied its targets and silently kept everything else.
  def build_full_clone_source
    source = build_clone_source
    source.update!(coverage_hours: '24x7', first_response_rule: 'first_comment',
                   at_risk_threshold: 65, stale_threshold_days: 9, pause_enabled: false)
    { created: @status_ids.first, work_started: @status_ids.second,
      resolved: @status_ids.first, pause: @status_ids.second }.each do |role, status_id|
      source.sla_status_mappings.create!(role: role.to_s, status_id: status_id)
    end
    source
  end

  test "cloning onto a project that ALREADY has its own policy copies every section" do
    source = build_full_clone_source
    # Give the target a complete policy of its own first, deliberately different in every field.
    put :update, params: general_params(sla_policy: { enabled: '0', coverage_hours: '24x7' })
    put :update, params: measurement_params(
      { sla_policy: { first_response_rule: 'first_status_change', at_risk_threshold: '95',
                      stale_threshold_days: '3' },
        status_mappings: { created: [@status_ids.second.to_s] } }
    )
    put :update, params: exclusions_params(sla_policy: { pause_enabled: '1' })
    assert_equal 95, policy.at_risk_threshold, 'precondition: the target owns a different policy'

    # The posted section carries what the prefilled form showed for the tracker on screen; the
    # source's other tracker rides along on the clone.
    put :update, params: targets_params(
      { clone_source_id: '2',
        definitions: { tracker_ids: [@trackers.first.id.to_s],
                       rows: { @trackers.first.id.to_s =>
                                 { @priorities.first.id.to_s => { response: '3600' } } } } }
    )

    saved = policy
    # General
    assert saved.enabled?, 'the source is enabled; the clone carries that (its General panel showed it)'
    # Measurement Rules
    assert_equal 'first_comment', saved.first_response_rule
    assert_equal 65, saved.at_risk_threshold
    assert_equal 9, saved.stale_threshold_days
    assert_equal [@status_ids.second], saved.status_ids_for(:work_started)
    assert_equal [@status_ids.first], saved.status_ids_for(:created),
                 "the target's own created-status must be replaced by the source's"
    # Exclusions
    refute saved.pause_enabled?
    assert_equal [@status_ids.second], saved.status_ids_for(:pause)
    # SLA Targets — both the tracker that was on screen and the one that was only in the source.
    assert_equal source.sla_definitions.count, saved.sla_definitions.count
    assert_equal 14_400, saved.sla_definitions
                              .find_by(tracker_id: @trackers.second.id).response_seconds,
                 'a tracker absent from the posted form still comes across with the clone'
  end

  test "cloning copies the source project's notification settings" do
    source = build_full_clone_source
    @role.add_permission!(:manage_sla_notifications)
    SlaNotificationSetting.create!(project_id: source.project_id,
                                   google_chat_webhook: 'https://chat.example.com/hook',
                                   at_risk_email_enabled: true,
                                   at_risk_email_recipients: ['ops@example.com'],
                                   at_risk_email_frequency: 'digest',
                                   at_risk_digest_interval_minutes: 30,
                                   stale_email_enabled: true,
                                   stale_email_frequency: 'daily', stale_threshold_days: 4,
                                   last_stale_digest_at: Time.zone.now)

    put :update, params: targets_params(clone_source_id: '2')

    copied = SlaNotificationSetting.find_by(project_id: @project.id)
    assert_not_nil copied, 'the clone must carry the notification setup across'
    assert_equal 'https://chat.example.com/hook', copied.google_chat_webhook
    assert copied.at_risk_email_enabled?
    assert_equal ['ops@example.com'], copied.at_risk_email_recipients
    assert_equal 'digest', copied.at_risk_email_frequency
    assert_equal 30, copied.at_risk_digest_interval_minutes
    assert copied.stale_email_enabled?
    assert_equal 'daily', copied.stale_email_frequency
    assert_equal 4, copied.stale_threshold_days
    assert_nil copied.last_stale_digest_at,
               'the digest SCHEDULE is per-project state — copying it would swallow the first digest'
  end

  test "cloning REPLACES notification settings the target already had" do
    source = build_full_clone_source
    @role.add_permission!(:manage_sla_notifications)
    SlaNotificationSetting.create!(project_id: source.project_id,
                                   google_chat_webhook: 'https://chat.example.com/source')
    SlaNotificationSetting.create!(project_id: @project.id,
                                   google_chat_webhook: 'https://chat.example.com/target')

    put :update, params: targets_params(clone_source_id: '2')

    assert_equal 'https://chat.example.com/source',
                 SlaNotificationSetting.find_by(project_id: @project.id).google_chat_webhook
  end

  # The webhook is effectively a secret, so :edit_sla_policy on the source — all a clone otherwise
  # needs — must not be enough to pull it into a project the user does control.
  test "cloning does NOT copy notifications without the notification permission, and says so" do
    source = build_full_clone_source
    SlaNotificationSetting.create!(project_id: source.project_id,
                                   google_chat_webhook: 'https://chat.example.com/secret')

    put :update, params: targets_params(clone_source_id: '2')

    assert_nil SlaNotificationSetting.find_by(project_id: @project.id),
               'the notification setup must not cross a permission boundary'
    assert flash[:warning].present?, 'a skipped copy has to be stated, not left to be assumed'
    assert_equal 1, policy.sla_status_mappings.where(role: 'pause').count,
                 'the rest of the policy still clones'
  end

  # Redmine renders flash content as RAW HTML (ApplicationHelper#render_flash_messages does
  # `content_tag('div', v.html_safe, ...)`) and Project#name has no format validation — only
  # presence and a 255-char limit. So a project name interpolated unescaped into a flash is stored
  # XSS: anyone who can rename a project that an SLA admin may clone from gets script execution in
  # that admin's session.
  test "a source project's name is escaped before it reaches the clone flash" do
    build_clone_source
    Project.find(2).update_column(:name, '<img src=x onerror=alert(1)>')

    put :update, params: targets_params(clone_source_id: '2')

    refute_includes flash[:notice].to_s, '<img src=x',
                    'the raw tag must never survive into a flash Redmine will mark html_safe'
    assert_includes flash[:notice].to_s, '&lt;img src=x'
  end

  test "clone load prefills the Notifications panel only when the copy would be allowed" do
    source = build_full_clone_source
    SlaNotificationSetting.create!(project_id: source.project_id,
                                   google_chat_webhook: 'https://chat.example.com/secret')

    get :edit, params: { project_id: @project.id, clone_from: '2' }, format: 'js', xhr: true
    assert_response :success
    refute_includes @response.body, 'chat.example.com/secret',
                    'the panel must never preview values the save would refuse to write'

    @role.add_permission!(:manage_sla_notifications)
    get :edit, params: { project_id: @project.id, clone_from: '2' }, format: 'js', xhr: true
    assert_response :success
    assert_includes @response.body, 'sla-policy-notifications-slot'
    assert_includes @response.body, 'chat.example.com/secret'
  end

  test "an unauthorized clone source is ignored on save" do
    source_project = Project.find(3) # jsmith is not a member
    SlaPolicy.create!(project_id: source_project.id, enabled: true)
             .sla_definitions.create!(tracker_id: @trackers.first.id,
                                      priority_id: @priorities.first.id,
                                      response_seconds: 3600)

    put :update, params: targets_params(clone_source_id: source_project.id.to_s)
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy', section: 'targets')
    assert_equal 0, policy.sla_definitions.count
  end

  # --- recalc tick (4.8) ----------------------------------------------------------------------

  test "recalculate tick enqueues the historical recalculation job" do
    SlaRecalculationState.delete_all
    assert_enqueued_jobs 1, only: SlaPolicyRecalculationJob do
      put :update, params: targets_params(recalculate: '1')
    end
    job = enqueued_jobs.last
    state = SlaRecalculationState.find_by!(project_id: @project.id)
    assert_equal [@project.id, state.run_token], job[:args]
    assert_nil flash[:sla_recalculation_token], 'the opaque run token must never render as a flash message'
  end

  test "AJAX recalculate save returns the run token without redirecting or flashing it" do
    put :update, params: targets_params(recalculate: '1'), xhr: true

    assert_response :success
    payload = response.parsed_body
    state = SlaRecalculationState.find_by!(project_id: @project.id)
    assert_equal state.run_token, payload.dig('recalculation', 'run_token')
    assert_equal 'queued', payload.dig('recalculation', 'status')
    assert_nil flash[:sla_recalculation_token]
  end

  test "save without the tick enqueues nothing" do
    assert_no_enqueued_jobs do
      put :update, params: targets_params
    end
  end

  # The tick only exists on the SLA Targets form, so a save from any other section must not
  # enqueue even if a `recalculate` param is forged onto it.
  test "the recalculate tick is ignored outside the SLA Targets section" do
    assert_no_enqueued_jobs do
      put :update, params: general_params(recalculate: '1')
    end
  end

  test "a failed save enqueues nothing even with the tick" do
    SlaTargetOption.create!(target_type: 'resolution', code: '1bd', label: '1 Business Day',
                            seconds: 28_800, basis: 'business') # invalid under 24x7 coverage

    assert_no_enqueued_jobs do
      put :update, params: targets_params(
        { recalculate: '1',
          definitions: { tracker_ids: [@trackers.first.id.to_s],
                         rows: { @trackers.first.id.to_s => { @priorities.first.id.to_s => { resolution: '28800' } } } } }
      )
    end
    assert flash[:error].present?
  end

  test "recalculation status is project-authorized and returns progress JSON" do
    state, = SlaRecalculationState.request!(@project)
    state.start!(state.run_token)
    state.record_progress!(state.run_token, processed: 2, total: 4)

    get :recalculation_status, params: { project_id: @project.id, run_token: state.run_token }

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal 'running', payload['status']
    assert_equal 2, payload['processed']
    assert_equal 4, payload['total']
    assert_equal 50, payload['progress']
  end

  test "recalculation status is forbidden without policy edit permission" do
    @role.remove_permission!(:edit_sla_policy)

    get :recalculation_status, params: { project_id: @project.id }

    assert_response :forbidden
  end

  test "recalculation status does not expose a superseded run token" do
    state, = SlaRecalculationState.request!(@project)

    get :recalculation_status, params: { project_id: @project.id, run_token: 'old-token' }

    assert_response :success
    assert_equal 'idle', JSON.parse(response.body)['status']
    assert_not_equal 'old-token', state.run_token
  end

  # --- dynamic re-renders (4.4 switch / 4.7 prefill) ------------------------------------------

  test "edit.js returns the definition rows of the requested tracker" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    priority = @priorities.first
    saved_policy.sla_definitions.create!(tracker_id: @trackers.second.id,
                                         priority_id: priority.id,
                                         response_seconds: 99_999) # unique marker, not in lookup

    get :edit, params: { project_id: @project.id, tracker_id: @trackers.second.id },
               format: 'js', xhr: true
    assert_response :success
    assert_includes @response.body, 'sla-definitions-rows'
    assert_includes @response.body, '99999'

    get :edit, params: { project_id: @project.id, tracker_id: @trackers.first.id },
               format: 'js', xhr: true
    assert_not_includes @response.body, '99999'
  end

  test "edit.js with clone_from returns the whole form prefilled from the source" do
    build_clone_source
    get :edit, params: { project_id: @project.id, clone_from: '2' }, format: 'js', xhr: true
    assert_response :success
    assert_includes @response.body, 'sla-policy-tab-body'
    assert_includes @response.body, 'clone_source_id'
  end

  test "edit.js with an unauthorized clone_from is a 404" do
    SlaPolicy.create!(project_id: 3, enabled: true)
    get :edit, params: { project_id: @project.id, clone_from: '3' }, format: 'js', xhr: true
    assert_response :not_found
  end

  # --- B3: Override via an ancestor the user has no direct edit rights on --------------------

  test "edit.js with clone_from an ANCESTOR project succeeds without direct edit rights there" do
    # @project (id 1) is the parent of project 5; jsmith is NOT separately granted
    # edit_sla_policy on project 1 here — only on the child, project 5.
    SlaPolicy.create!(project_id: @project.id, enabled: true, first_response_rule: 'either')
    child = Project.find(5)
    child.enable_module!(:sla_compliance)
    member = Member.find_or_initialize_by(user_id: 2, project_id: child.id)
    member.role_ids = (member.role_ids + [@role.id]).uniq
    member.save!

    get :edit, params: { project_id: child.id, clone_from: @project.id.to_s }, format: 'js', xhr: true

    assert_response :success
    assert_includes @response.body, 'sla-policy-tab-body'
  end

  test "edit.js with clone_from an unrelated, unauthorized project is still a 404" do
    SlaPolicy.create!(project_id: 3, enabled: true) # not an ancestor of @project, no direct rights
    get :edit, params: { project_id: @project.id, clone_from: '3' }, format: 'js', xhr: true
    assert_response :not_found
  end

  # --- B3: Revert to inherited policy (destroy) -----------------------------------------------

  test "destroy removes the project's own policy and its definitions/mappings" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    saved_policy.sla_definitions.create!(tracker_id: @trackers.first.id,
                                         priority_id: @priorities.first.id, response_seconds: 3600)
    saved_policy.sla_status_mappings.create!(role: 'created', status_id: @status_ids.first)

    delete :destroy, params: { project_id: @project.id }

    assert_redirected_to settings_project_path(@project, tab: 'sla_policy')
    assert_nil SlaPolicy.find_by(project_id: @project.id)
    assert_equal 0, SlaDefinition.where(sla_policy_id: saved_policy.id).count
    assert_equal 0, SlaStatusMapping.where(sla_policy_id: saved_policy.id).count
  end

  test "destroy enqueues a recalculation and never touches sla_results" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    result = SlaResult.create!(issue_id: 999_001, project_id: @project.id, primary_state: 'met')

    assert_enqueued_jobs 1, only: SlaPolicyRecalculationJob do
      delete :destroy, params: { project_id: @project.id }
    end

    assert SlaResult.exists?(result.id), 'sla_results must never be deleted by a revert'
    assert_equal @project.id, enqueued_jobs.last[:args].first
  end

  test "destroy is a no-op (no error) when the project has no own policy to revert" do
    assert_nothing_raised { delete :destroy, params: { project_id: @project.id } }
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy')
  end

  test "destroy is forbidden without edit_sla_policy" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    @role.remove_permission!(:edit_sla_policy)

    delete :destroy, params: { project_id: @project.id }

    assert_response :forbidden
    assert SlaPolicy.exists?(project_id: @project.id)
  end

  # --- Tri-state SLA on/off for an inheriting subproject --------------------------------------
  # section=enablement writes a LIGHTWEIGHT row (inherits_config: true) carrying only the on/off
  # decision, so the child keeps following the ancestor's configuration. It must never be able to
  # reach the field-writing path, and must never strip a self-defining row's flag.

  # @project (id 1) is the parent of project 5; the child inherits and jsmith can edit it.
  def inheriting_child
    parent_policy = SlaPolicy.create!(project_id: @project.id, enabled: true,
                                       first_response_rule: 'either', at_risk_threshold: 90)
    child = Project.find(5)
    child.enable_module!(:sla_compliance)
    member = Member.find_or_initialize_by(user_id: 2, project_id: child.id)
    member.role_ids = (member.role_ids + [@role.id]).uniq
    member.save!
    [child, parent_policy]
  end

  def enablement_params(project, value)
    { project_id: project.id, tab: 'sla_policy', section: 'enablement',
      sla_policy: { enablement: value } }
  end

  test "enablement=disabled writes a lightweight row that switches SLA off for the child only" do
    child, parent_policy = inheriting_child

    put :update, params: enablement_params(child, 'disabled')

    assert_redirected_to settings_project_path(child, tab: 'sla_policy')
    policy = SlaPolicy.find_by(project_id: child.id)
    assert policy.inherits_config?, 'must be a lightweight row, not a forked configuration'
    refute policy.enabled?
    assert_nil SlaPolicy.effective_for(child)
    assert_equal parent_policy, SlaPolicy.effective_for(@project), 'the parent is untouched'
  end

  test "enablement=enabled switches SLA on for a child under a disabled parent" do
    child, parent_policy = inheriting_child
    parent_policy.update!(enabled: false)

    put :update, params: enablement_params(child, 'enabled')

    assert_equal parent_policy, SlaPolicy.effective_for(child),
                 "the child's decision wins, and the parent still supplies the configuration"
  end

  test "enablement=inherit clears the child's lightweight row" do
    child, parent_policy = inheriting_child
    SlaPolicy.create!(project_id: child.id, enabled: false, inherits_config: true)

    put :update, params: enablement_params(child, 'inherit')

    assert_nil SlaPolicy.find_by(project_id: child.id)
    assert_equal parent_policy, SlaPolicy.effective_for(child)
  end

  test "enablement enqueues a recalculation, since cached results change meaning" do
    child, = inheriting_child

    assert_enqueued_jobs 1, only: SlaPolicyRecalculationJob do
      put :update, params: enablement_params(child, 'disabled')
    end
    assert_equal child.id, enqueued_jobs.last[:args].first
  end

  test "enablement writes nothing but the on/off decision, whatever else is posted" do
    child, = inheriting_child

    put :update, params: enablement_params(child, 'enabled').deep_merge(
      sla_policy: { at_risk_threshold: '5', coverage_hours: 'business_hours',
                    first_response_rule: 'first_comment' }
    )

    policy = SlaPolicy.find_by(project_id: child.id)
    assert policy.enabled?
    assert_equal 80, policy.at_risk_threshold, 'posted policy fields must not reach this path'
    assert_equal '24x7', policy.coverage_hours
  end

  test "enablement is refused on a project that defines its own configuration" do
    own = SlaPolicy.create!(project_id: @project.id, enabled: true, at_risk_threshold: 90)

    put :update, params: enablement_params(@project, 'disabled')

    assert_response :forbidden
    own.reload
    assert own.enabled?, 'a self-defining row uses the General section, not this path'
    refute own.inherits_config?
  end

  test "an unrecognised enablement value falls back to inherit rather than enabling SLA" do
    child, = inheriting_child
    SlaPolicy.create!(project_id: child.id, enabled: false, inherits_config: true)

    put :update, params: enablement_params(child, 'something-else')

    assert_nil SlaPolicy.find_by(project_id: child.id)
  end

  test "enablement is forbidden without edit_sla_policy" do
    child, = inheriting_child
    @role.remove_permission!(:edit_sla_policy)

    put :update, params: enablement_params(child, 'disabled')

    assert_response :forbidden
    assert_nil SlaPolicy.find_by(project_id: child.id)
  end

  test "saving a policy section over a lightweight row makes it self-defining again" do
    child, = inheriting_child
    SlaPolicy.create!(project_id: child.id, enabled: false, inherits_config: true)

    put :update, params: general_params(project_id: child.id)

    policy = SlaPolicy.find_by(project_id: child.id)
    refute policy.inherits_config?, 'the Override path writes configuration, so the row owns it'
    assert policy.enabled?
  end
end
