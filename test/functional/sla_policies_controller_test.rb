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

    # Admin lookup the target dropdowns post from.
    @opt_1h = SlaTargetOption.create!(target_type: 'response', code: '1h', label: '1 hour',
                                      seconds: 3600)
    @opt_4h = SlaTargetOption.create!(target_type: 'response', code: '4h', label: '4 hours',
                                      seconds: 14_400)
    @opt_2h = SlaTargetOption.create!(target_type: 'workaround', code: '2h', label: '2 hours',
                                      seconds: 7200)
    @opt_1d = SlaTargetOption.create!(target_type: 'resolution', code: '1d', label: '1 day',
                                      seconds: 86_400)
  end

  def base_params(overrides = {})
    { project_id: @project.id,
      tab: 'sla_policy',
      sla_policy: { enabled: '1', coverage_hours: '24x7', business_calendar_id: '',
                    first_response_rule: 'first_comment', at_risk_threshold: '75',
                    pause_enabled: '1' } }.deep_merge(overrides)
  end

  def policy
    SlaPolicy.find_by(project_id: @project.id)
  end

  # --- gating -------------------------------------------------------------------------------

  test "update is forbidden without edit_sla_policy" do
    @role.remove_permission!(:edit_sla_policy)
    put :update, params: base_params
    assert_response :forbidden
    assert_nil policy
  end

  test "manage_sla_notifications alone does not grant the policy actions" do
    @role.remove_permission!(:edit_sla_policy)
    @role.add_permission!(:manage_sla_notifications)
    put :update, params: base_params
    assert_response :forbidden
  end

  test "update is forbidden when the module is disabled" do
    @project.disable_module!(:sla_compliance)
    put :update, params: base_params
    assert_response :forbidden
  end

  # --- scalars (4.2 / 4.3 / 4.8 defaults) ---------------------------------------------------

  test "update persists policy scalars and redirects to the tab" do
    put :update, params: base_params
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy')
    saved = policy
    assert saved.enabled?
    assert_equal '24x7', saved.coverage_hours
    assert_equal 'first_comment', saved.first_response_rule
    assert_equal 75, saved.at_risk_threshold
    assert saved.pause_enabled?
  end

  test "business hours coverage persists with its calendar" do
    calendar = SlaBusinessCalendar.create!(name: 'Std', working_days: [1, 2, 3, 4, 5],
                                           work_start_time: '09:00', work_end_time: '17:00')
    put :update, params: base_params(
      sla_policy: { coverage_hours: 'business_hours', business_calendar_id: calendar.id.to_s }
    )
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy')
    assert_equal calendar.id, policy.business_calendar_id
  end

  test "business hours without a calendar fails atomically" do
    put :update, params: base_params(
      { sla_policy: { coverage_hours: 'business_hours' },
        status_mappings: { created: [@status_ids.first.to_s] } }
    )
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy')
    assert flash[:error].present?
    assert_nil policy
    assert_equal 0, SlaStatusMapping.count
  end

  # --- status mappings (4.3 / 4.5) ----------------------------------------------------------

  test "status selections persist as ID rows per role" do
    created = @status_ids.first(2)
    resolved = [@status_ids.last]
    put :update, params: base_params(
      status_mappings: { created: created.map(&:to_s),
                         resolved: resolved.map(&:to_s),
                         pause: resolved.map(&:to_s) }
    )
    saved = policy
    assert_equal created.sort, saved.status_ids_for(:created).sort
    assert_equal resolved, saved.status_ids_for(:resolved)
    assert_equal resolved, saved.status_ids_for(:pause)
    assert_equal [], saved.status_ids_for(:work_started)
  end

  test "resubmitting different statuses diff-replaces, and omitting a role clears it" do
    put :update, params: base_params(
      status_mappings: { created: @status_ids.first(2).map(&:to_s),
                         pause: [@status_ids.last.to_s] }
    )
    put :update, params: base_params(
      status_mappings: { created: [@status_ids[1].to_s] } # pause omitted -> cleared
    )
    saved = policy
    assert_equal [@status_ids[1]], saved.status_ids_for(:created)
    assert_equal [], saved.status_ids_for(:pause)
  end

  # Phase-4-level regression (C): the engine-level "empty pause list = no pause" guard is already
  # tested in isolation at Phase 2 (Sla::PauseCalculator), but nothing previously proved the UI
  # form's save path actually WIRES an empty selection through to that behavior end-to-end.
  test "an empty pause list saved via the form round-trips into no pause subtraction at the engine level" do
    work_status = @status_ids.second
    put :update, params: base_params(
      status_mappings: { created: [@status_ids.first.to_s] }, # pause intentionally left empty
      definitions: { tracker_id: @trackers.first.id.to_s,
                     rows: { @priorities.first.id.to_s => { response: @opt_1h.seconds.to_s } } }
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
    put :update, params: base_params(
      status_mappings: { created: [foreign.id.to_s, @status_ids.first.to_s] }
    )
    assert_equal [@status_ids.first], policy.status_ids_for(:created)
  end

  # --- definitions (4.4) ---------------------------------------------------------------------

  test "targets persist per tracker and priority as seconds from the lookup" do
    priority = @priorities.first
    put :update, params: base_params(
      definitions: { tracker_id: @trackers.first.id.to_s,
                     rows: { priority.id.to_s => { response: '3600', workaround: '7200',
                                                   resolution: '86400' } } }
    )
    definition = policy.sla_definitions.find_by(tracker_id: @trackers.first.id,
                                                priority_id: priority.id)
    assert definition
    assert_equal 3600, definition.response_seconds
    assert_equal 7200, definition.workaround_seconds
    assert_equal 86_400, definition.resolution_seconds
  end

  test "saving replaces only the posted tracker's definitions" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    priority = @priorities.first
    keep = saved_policy.sla_definitions.create!(tracker_id: @trackers.first.id,
                                                priority_id: priority.id,
                                                response_seconds: 3600)
    saved_policy.sla_definitions.create!(tracker_id: @trackers.second.id,
                                         priority_id: priority.id, response_seconds: 3600)

    put :update, params: base_params(
      definitions: { tracker_id: @trackers.second.id.to_s,
                     rows: { priority.id.to_s => { response: '14400' } } }
    )

    assert_equal 3600, keep.reload.response_seconds # tracker 1 untouched
    replaced = policy.sla_definitions.find_by(tracker_id: @trackers.second.id,
                                              priority_id: priority.id)
    assert_equal 14_400, replaced.response_seconds
  end

  test "a priority with every target blank gets no definition row" do
    priority = @priorities.first
    put :update, params: base_params(
      definitions: { tracker_id: @trackers.first.id.to_s,
                     rows: { priority.id.to_s => { response: '', workaround: '',
                                                   resolution: '' } } }
    )
    assert_equal 0, policy.sla_definitions.count
  end

  test "seconds not in the lookup are rejected" do
    priority = @priorities.first
    put :update, params: base_params(
      definitions: { tracker_id: @trackers.first.id.to_s,
                     rows: { priority.id.to_s => { response: '12345' } } }
    )
    assert_equal 0, policy.sla_definitions.count
  end

  # --- Best Effort + basis (B4) --------------------------------------------------------------

  test "posting 'best_effort' persists a Best Effort target with no seconds value" do
    SlaTargetOption.create!(target_type: 'resolution', code: 'be', label: 'Best Effort',
                            best_effort: true)
    priority = @priorities.first

    put :update, params: base_params(
      definitions: { tracker_id: @trackers.first.id.to_s,
                     rows: { priority.id.to_s => { resolution: 'best_effort' } } }
    )

    definition = policy.sla_definitions.find_by(tracker_id: @trackers.first.id, priority_id: priority.id)
    assert definition.resolution_best_effort?
    assert_nil definition.resolution_seconds
  end

  test "posting 'best_effort' is rejected when no Best Effort option is configured for that type" do
    priority = @priorities.first

    put :update, params: base_params(
      definitions: { tracker_id: @trackers.first.id.to_s,
                     rows: { priority.id.to_s => { resolution: 'best_effort' } } }
    )

    assert_equal 0, policy.sla_definitions.count
  end

  test "a business-basis target under 24x7x365 coverage fails the save atomically" do
    SlaTargetOption.create!(target_type: 'resolution', code: '1bd', label: '1 Business Day',
                            seconds: 28_800, basis: 'business')
    priority = @priorities.first

    put :update, params: base_params(
      { sla_policy: { coverage_hours: '24x7' },
        definitions: { tracker_id: @trackers.first.id.to_s,
                       rows: { priority.id.to_s => { resolution: '28800' } } } }
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

    put :update, params: base_params(
      { sla_policy: { coverage_hours: 'business_hours', business_calendar_id: calendar.id.to_s },
        definitions: { tracker_id: @trackers.first.id.to_s,
                       rows: { priority.id.to_s => { resolution: '28800' } } } }
    )

    refute flash[:error].present?
    definition = policy.sla_definitions.find_by(tracker_id: @trackers.first.id, priority_id: priority.id)
    assert_equal 28_800, definition.resolution_seconds
  end

  test "a posted row for the admin-designated unclassified priority is rejected" do
    none = IssuePriority.create!(name: 'None', type: 'IssuePriority', position: 99)
    Setting.plugin_redmine_sla_compliance = { 'unclassified_priority_id' => none.id.to_s }

    put :update, params: base_params(
      definitions: { tracker_id: @trackers.first.id.to_s,
                     rows: { none.id.to_s => { response: @opt_1h.seconds.to_s } } }
    )

    assert_equal 0, policy.sla_definitions.where(priority_id: none.id).count
  ensure
    Setting.plugin_redmine_sla_compliance = {}
  end

  test "a previously saved value survives even after the lookup changed" do
    saved_policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    priority = @priorities.first
    saved_policy.sla_definitions.create!(tracker_id: @trackers.first.id,
                                         priority_id: priority.id,
                                         response_seconds: 99_999) # no longer in the lookup

    put :update, params: base_params(
      definitions: { tracker_id: @trackers.first.id.to_s,
                     rows: { priority.id.to_s => { response: '99999' } } }
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

    put :update, params: base_params(
      { clone_source_id: '2',
        sla_policy: { at_risk_threshold: '90', first_response_rule: 'either' },
        definitions: { tracker_id: @trackers.second.id.to_s,
                       rows: { priority.id.to_s => { response: '3600' } } } }
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

  test "cloning skips a source definition saved for the unclassified priority" do
    source = build_clone_source
    none = IssuePriority.create!(name: 'None', type: 'IssuePriority', position: 99)
    source.sla_definitions.create!(tracker_id: @trackers.first.id, priority_id: none.id,
                                   response_seconds: 3600)
    Setting.plugin_redmine_sla_compliance = { 'unclassified_priority_id' => none.id.to_s }

    put :update, params: base_params(
      { clone_source_id: '2',
        definitions: { tracker_id: @trackers.second.id.to_s, rows: {} } }
    )

    assert_equal 0, policy.sla_definitions.where(priority_id: none.id).count
  ensure
    Setting.plugin_redmine_sla_compliance = {}
  end

  test "an unauthorized clone source is ignored on save" do
    source_project = Project.find(3) # jsmith is not a member
    SlaPolicy.create!(project_id: source_project.id, enabled: true)
             .sla_definitions.create!(tracker_id: @trackers.first.id,
                                      priority_id: @priorities.first.id,
                                      response_seconds: 3600)

    put :update, params: base_params(clone_source_id: source_project.id.to_s)
    assert_redirected_to settings_project_path(@project, tab: 'sla_policy')
    assert_equal 0, policy.sla_definitions.count
  end

  # --- recalc tick (4.8) ----------------------------------------------------------------------

  test "recalculate tick enqueues the historical recalculation job" do
    assert_enqueued_with(job: SlaPolicyRecalculationJob, args: [@project.id]) do
      put :update, params: base_params(recalculate: '1')
    end
  end

  test "save without the tick enqueues nothing" do
    assert_no_enqueued_jobs do
      put :update, params: base_params
    end
  end

  test "a failed save enqueues nothing even with the tick" do
    assert_no_enqueued_jobs do
      put :update, params: base_params(
        { recalculate: '1', sla_policy: { coverage_hours: 'business_hours' } }
      )
    end
    assert flash[:error].present?
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
    assert_includes @response.body, 'sla-policy-form-container'
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
    assert_includes @response.body, 'sla-policy-form-container'
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

    assert_enqueued_with(job: SlaPolicyRecalculationJob, args: [@project.id]) do
      delete :destroy, params: { project_id: @project.id }
    end

    assert SlaResult.exists?(result.id), 'sla_results must never be deleted by a revert'
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
end
