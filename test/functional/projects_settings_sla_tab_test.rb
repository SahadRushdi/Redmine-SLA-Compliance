require_relative '../test_helper'

# Renders the real Project Settings page end-to-end: proves the tab partial, both form
# sections, the helper wiring into ProjectsController, and the per-permission section gating.
class ProjectsSettingsSlaTabTest < ActionController::TestCase
  tests ProjectsController

  fixtures :projects, :projects_trackers, :trackers, :issue_statuses, :workflows,
           :enumerations, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules

  setup do
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    @role = Role.find(1) # Manager — user 2 (jsmith)
    @role.add_permission!(:edit_sla_policy, :manage_sla_notifications)
    @request.session[:user_id] = 2
    SlaTargetOption.create!(target_type: 'response', code: '4h', label: '4 hours',
                            seconds: 14_400)
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  # Regression: an ERB comment in _setting_card.html.erb illustrated the partial's usage with a
  # snippet, and the snippet's own closing tag ended the comment early — so the remainder of the
  # doc comment rendered as visible text above the SLA Tracking and Coverage Hours cards. Nothing
  # else caught it: the page still returned 200 and every field assertion still passed. Scans the
  # whole rendered tab rather than that one partial, since the trap applies to any of them.
  test "no ERB source leaks into the rendered SLA Policy tab" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }

    assert_response :success
    tab = css_select('#tab-content-sla_policy').first
    assert tab.present?, 'SLA Policy tab did not render'
    text = tab.text
    %w[<% %> <%= <%#].each do |marker|
      assert_not_includes text, marker,
                          "ERB source #{marker} leaked into the page — an ERB comment probably " \
                          'contains a closing tag and was terminated early'
    end
  end

  # The sibling failure mode, which the ERB-marker scan above does NOT catch: a tag closed early,
  # so its remaining ATTRIBUTES render as visible text. It bit `tag.attributes(...)`, the obvious
  # way to emit an attribute conditionally — it does not exist in Rails 6.1 (added in 7.0), and
  # TagBuilder#method_missing silently builds an `<attributes …>` ELEMENT from it instead, which
  # lands inside the opening tag and terminates it at its own `>`. The page still returned 200 and
  # every assert_select in this file still passed; only the rendered text showed it.
  test "no HTML attributes leak as text into the rendered SLA Policy tab" do
    SlaPolicy.create!(project_id: @project.id, enabled: false) # renders the lock's markup too

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }

    assert_response :success
    text = css_select('#tab-content-sla_policy').first.text
    %w[aria-current= data-sla- class=" href=" <attributes].each do |marker|
      assert_not_includes text, marker,
                          "#{marker} rendered as visible text — an opening tag was closed early, " \
                          'most likely by markup emitted into the middle of it'
    end
  end

  test "settings page renders both tab sections with saved values" do
    saved = SlaPolicy.create!(project_id: @project.id, enabled: true, at_risk_threshold: 85)
    status_id = @project.rolled_up_statuses.first.id
    saved.sla_status_mappings.create!(role: 'created', status_id: status_id)
    saved.sla_definitions.create!(tracker_id: @project.trackers.first.id,
                                  priority_id: IssuePriority.active.first.id,
                                  response_seconds: 14_400)
    SlaNotificationSetting.create!(project_id: @project.id,
                                   at_risk_email_recipients: ['ops@example.com'])

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#tab-content-sla_policy .sla-plugin' do
      assert_select '#sla-policy-form'
      assert_select '#sla-notification-form'
      assert_select 'input#sla_policy_at_risk_threshold[value="85"]'
      assert_select "select[name='status_mappings[created][]'] option[selected][value='#{status_id}']"
      assert_select "#sla-definitions-rows-#{@project.trackers.first.id} " \
                    'option[selected][value="14400"]'
      assert_select "option[selected][value='ops@example.com']"
    end
  end

  test "policy section is hidden for a notifications-only role" do
    @role.remove_permission!(:edit_sla_policy)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success
    assert_select '#sla-policy-form', 0
    assert_select '#sla-notification-form'
  end

  # --- Sectioned settings shell ----------------------------------------------------------------

  test "the sidebar lists every section and opens General by default" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    SlaPoliciesHelper::SECTIONS.each do |section|
      assert_select "a[data-sla-section-link='#{section[:key]}']", 1,
                    "the #{section[:key]} section must be reachable from the sidebar"
      assert_select "[data-sla-panel='#{section[:key]}']", 1
    end
    assert_select "a[data-sla-section-link='general'].is-active"
    assert_select "[data-sla-panel='general']:not(.hidden)"
    assert_select "[data-sla-panel='targets'].hidden"
  end

  test "the requested section is the one rendered open" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'exclusions' }
    assert_response :success

    assert_select "a[data-sla-section-link='exclusions'].is-active"
    assert_select "[data-sla-panel='exclusions']:not(.hidden)"
    assert_select "[data-sla-panel='general'].hidden"
  end

  test "an unknown section falls back to the first permitted one" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'nope' }
    assert_response :success
    assert_select "a[data-sla-section-link='general'].is-active"
  end

  # Regression: the clone/Override AJAX replaces #sla-policy-tab-body wholesale. The Notifications
  # form belongs to a different controller and its own save button, so it must sit OUTSIDE that
  # region — otherwise loading a clone source silently discards a webhook URL or recipient list
  # the user had typed but not yet saved.
  test "the notifications form is outside the region the clone AJAX replaces" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#sla-policy-tab-body #sla-notification-form', 0,
                  'a clone load would wipe unsaved notification input if the form were in here'
    assert_select '#sla-policy-tab-body' # the region itself still exists
    assert_select '#sla-notification-form'
  end

  test "a notifications-only role gets a sidebar of just that section, opened" do
    @role.remove_permission!(:edit_sla_policy)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select 'a[data-sla-section-link]', 1
    assert_select "a[data-sla-section-link='notifications'].is-active"
    assert_select "[data-sla-panel='notifications']:not(.hidden)"
  end

  # --- Locking the configuration sections while SLA tracking is off ----------------------------
  # SLA Targets, Measurement Rules, Exclusions and Notifications describe how an ACTIVE policy
  # behaves, so they go read-only while tracking is off — otherwise someone can spend an afternoon
  # configuring a policy that is never evaluated. The lock is one <fieldset disabled> per section,
  # which matters beyond appearance: a control inside a disabled fieldset is not submitted, so a
  # locked section cannot be posted even by hand.

  # Every section EXCEPT General, which owns the switch that would unlock the others — locking it
  # would be a one-way door.
  LOCKED_PANELS = %w[targets measurement exclusions notifications].freeze

  test "the four configuration sections are locked while SLA tracking is off" do
    SlaPolicy.create!(project_id: @project.id, enabled: false)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    LOCKED_PANELS.each do |key|
      assert_select "[data-sla-panel='#{key}'] fieldset[data-sla-lock][disabled]", 1,
                    "the #{key} section must be disabled while tracking is off"
      assert_select "[data-sla-panel='#{key}'] [data-sla-locked-notice]:not(.hidden)", 1,
                    "the #{key} section must say why its controls are inert"
      assert_select "a[data-sla-section-link='#{key}'].is-locked", 1
    end
  end

  test "General stays editable and unlocked while SLA tracking is off" do
    SlaPolicy.create!(project_id: @project.id, enabled: false)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select "[data-sla-panel='general'] fieldset[data-sla-lock]", 0,
                  'General is where tracking is switched back on — locking it strands the project'
    assert_select "a[data-sla-section-link='general'].is-locked", 0
    assert_select "input[type=checkbox][name='sla_policy[enabled]']:not([disabled])", 1
  end

  test "nothing is locked while SLA tracking is on" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select 'fieldset[data-sla-lock][disabled]', 0
    assert_select 'a[data-sla-section-link].is-locked', 0
    # The banner is rendered either way so the JS can reveal it the moment the switch flips; while
    # tracking is on it must be hidden, not merely absent from view by accident.
    assert_select '[data-sla-locked-notice]', LOCKED_PANELS.size
    assert_select '[data-sla-locked-notice]:not(.hidden)', 0
  end

  # The locked banner sends the user to the one section that can undo the lock.
  test "the locked banner links back to the General section" do
    SlaPolicy.create!(project_id: @project.id, enabled: false)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select "[data-sla-locked-notice] a[data-sla-goto-section='general']" \
                  "[href*='section=general']", LOCKED_PANELS.size
  end

  # A notifications-only manager cannot reach General, so pointing them at it would be a dead end —
  # the banner still explains the lock, just without a link.
  test "the locked banner is unlinked when General is not on offer" do
    @role.remove_permission!(:edit_sla_policy)
    SlaPolicy.create!(project_id: @project.id, enabled: false)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '[data-sla-locked-notice]:not(.hidden)', 1
    assert_select '[data-sla-locked-notice] a', 0
  end

  # An inheriting project's on/off decision lives in the TRI-STATE control, not the plain switch,
  # so the lock has to resolve that instead — including :inherit, which means asking the ancestor.

  test "an inheriting project locks on its own Disabled decision" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    SlaPolicy.create!(project_id: child.id, enabled: false, inherits_config: true)

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select 'fieldset[data-sla-lock][disabled]', LOCKED_PANELS.size
  end

  test "an inheriting project follows its ancestor while set to Inherit" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true)

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select "input[name='sla_policy[enablement]'][value='inherit'][checked]"
    assert_select 'fieldset[data-sla-lock][disabled]', 0, 'the ancestor has tracking on'
  end

  test "an inheriting project locks when the ancestor it inherits from is off" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: false)

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select 'fieldset[data-sla-lock][disabled]', LOCKED_PANELS.size
  end

  # --- Section bodies ---------------------------------------------------------------------------

  # The unclassified priority can never hold a target (enforced in
  # SlaPoliciesController#replace_tracker_definitions!), so the Priority Targets card states that
  # once in a notice rather than rendering a permanently disabled row. Rendering inputs for it
  # would be worse than redundant — it would invite a submission the server is bound to discard.
  test "the unclassified priority is a notice above the table, never a row with inputs" do
    none = IssuePriority.active.first
    Setting.plugin_redmine_sla_compliance = { 'unclassified_priority_id' => none.id.to_s }
    classified = IssuePriority.active.detect { |p| p.id != none.id }

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }
    assert_response :success

    tracker_id = @project.trackers.sorted.first.id
    assert_select '[data-sla-panel="targets"]' do
      assert_select "select[name^='definitions[rows][#{tracker_id}][#{none.id}]']", 0,
                    'no input may be offered for a priority whose submission is always rejected'
      assert_select "select[name='definitions[rows][#{tracker_id}][#{classified.id}][response]']", 1,
                    'other priorities must still get their target dropdowns'
    end
  end

  test "with no unclassified priority configured every active priority gets a row" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }
    assert_response :success

    tracker_id = @project.trackers.sorted.first.id
    IssuePriority.active.each do |priority|
      assert_select "select[name='definitions[rows][#{tracker_id}][#{priority.id}][response]']", 1
    end
  end

  # --- Step 6.2a: the Stale threshold field, and the "what happens if I leave this empty" line ---

  def get_measurement_section(project = @project)
    get :settings, params: { id: project.identifier, tab: 'sla_policy', section: 'measurement' }
    assert_response :success
  end

  test "the Measurement Rules section offers the stale threshold field" do
    get_measurement_section

    assert_select '[data-sla-panel="measurement"]' do
      assert_select "input[name='sla_policy[stale_threshold_days]']", 1
    end
  end

  test "a project with its own threshold shows it in the field" do
    SlaPolicy.create!(project_id: @project.id, enabled: true, stale_threshold_days: 4)

    get_measurement_section

    assert_select "input[name='sla_policy[stale_threshold_days]'][value='4']", 1
  end

  test "with nothing set anywhere the field is empty and says so" do
    get_measurement_section

    assert_select "input[name='sla_policy[stale_threshold_days]'][value]", 0, 'no value, so it inherits'
    assert_select '#sla-stale-threshold-source', text: I18n.t(:text_sla_stale_threshold_unset_anywhere)
  end

  test "a subproject shows which ancestor its inherited threshold comes from" do
    child = Project.find(5) # parent = @project (1)
    child.enable_module!(:sla_compliance)
    SlaPolicy.create!(project_id: @project.id, enabled: true, stale_threshold_days: 4)

    get_measurement_section(child)

    assert_select '#sla-stale-threshold-source',
                  text: I18n.t(:text_sla_stale_threshold_inherited, days: 4, source: @project.name)
    # The placeholder repeats it inside the empty box, so the number is visible where it is typed.
    assert_select "input[name='sla_policy[stale_threshold_days]'][placeholder=?]",
                  I18n.t(:label_sla_stale_threshold_placeholder_inherited, days: 4)
  end

  # A project's OWN value must not be described as something it inherits — the line answers
  # "what applies if this box is empty", which is the parent's answer, never its own.
  test "a project's own value is not reported as inherited from itself" do
    SlaPolicy.create!(project_id: @project.id, enabled: true, stale_threshold_days: 9)

    get_measurement_section

    assert_select '#sla-stale-threshold-source', text: I18n.t(:text_sla_stale_threshold_unset_anywhere)
  end

  test "every configured target type gets its own column, header and dropdown per priority" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }
    assert_response :success

    tracker_id = @project.trackers.sorted.first.id
    priority   = IssuePriority.active.first
    SlaDefinition::TARGET_TYPES.each do |target_type|
      assert_select "select[name='definitions[rows][#{tracker_id}][#{priority.id}][#{target_type}]']", 1,
                    "#{target_type} must have a dropdown on every priority row"
      # Title case from the i18n value, never an uppercase CSS transform (CLAUDE.md).
      assert_select "#sla-definitions-table-#{tracker_id} thead th",
                    text: I18n.t("label_sla_target_#{target_type}"), count: 1
    end
  end

  # A disabled alert card collapses to just its switch, but its fields stay in the DOM and keep
  # posting — otherwise turning an alert off and on again would silently drop the recipients the
  # project had already saved.
  test "a disabled alert card hides its detail fields without dropping them from the form" do
    SlaNotificationSetting.create!(project_id: @project.id, at_risk_email_enabled: false,
                                   at_risk_email_recipients: ['ops@example.com'])

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'notifications' }
    assert_response :success

    assert_select '[data-sla-reveal="at-risk-email"].hidden'
    assert_select '#sla-notification-form select#sla-at-risk-recipients' do
      assert_select "option[selected][value='ops@example.com']"
    end
  end

  test "an enabled alert card renders its detail fields open" do
    SlaNotificationSetting.create!(project_id: @project.id, at_risk_email_enabled: true)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'notifications' }
    assert_response :success

    assert_select '[data-sla-reveal="at-risk-email"]:not(.hidden)'
    # The switch has to name the block it owns, or the JS has nothing to bind the two together by.
    assert_select 'input[data-sla-reveals="at-risk-email"][type=checkbox]'
  end

  test "the tab is absent without either permission" do
    @role.remove_permission!(:edit_sla_policy, :manage_sla_notifications)

    get :settings, params: { id: @project.identifier }
    assert_response :success
    assert_select '#tab-content-sla_policy', 0
  end

  # --- B3: inheritance banner, not a blank editable form ---------------------------------------
  #
  # The bug being regression-tested: a child project with no SLA policy of its own used to render
  # the SAME blank editable form as a project with no policy anywhere — and saving that blank
  # form silently created a disabled override, defeating inheritance. A child with an inherited
  # policy must never show `#sla-policy-form` at all.

  def grant_child_access(project)
    member = Member.find_or_initialize_by(user_id: 2, project_id: project.id)
    member.role_ids = (member.role_ids + [@role.id]).uniq
    member.save!
    project.enable_module!(:sla_compliance)
  end

  test "an inheriting project gets the full editable form, pre-filled from its ancestor" do
    child = Project.find(5) # private-child, parent = ecookbook (1)
    grant_child_access(child)
    parent_policy = SlaPolicy.create!(project_id: @project.id, enabled: true,
                                      at_risk_threshold: 85, first_response_rule: 'either')
    status_id = @project.rolled_up_statuses.first.id
    parent_policy.sla_status_mappings.create!(role: 'created', status_id: status_id)
    parent_policy.sla_definitions.create!(tracker_id: child.trackers.first.id,
                                          priority_id: IssuePriority.active.first.id,
                                          response_seconds: 14_400)

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    # Same sidebar and same sections as the project it inherits from — no read-only summary.
    %w[general measurement targets exclusions notifications].each do |key|
      assert_select "a[data-sla-section-link='#{key}']"
    end
    assert_select '#sla-policy-form'
    # ...and every control carries the INHERITED value, so nothing can be saved from a field the
    # user was never shown.
    assert_select 'input#sla_policy_at_risk_threshold[value="85"]'
    assert_select "select[name='status_mappings[created][]'] option[selected][value='#{status_id}']"
    assert_select "#sla-definitions-rows-#{child.trackers.first.id} " \
                  'option[selected][value="14400"]'
    assert_select 'button#sla-override-load', 0, 'the form itself is the override now'
  end

  # --- Tri-state SLA on/off above the inherited (pre-filled) sections --------------------------

  test "the inherited policy offers the tri-state control, defaulted to Inherit" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true)

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select 'form#sla-enablement-form' do
      assert_select "input[name='sla_policy[enablement]'][value='inherit'][checked]"
      assert_select "input[name='sla_policy[enablement]'][value='enabled']:not([checked])"
      assert_select "input[name='sla_policy[enablement]'][value='disabled']:not([checked])"
      assert_select "input[name='section'][value='enablement']", 1
    end
  end

  test "a lightweight row keeps the banner, preselects its own decision, and reports the effective state" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    SlaPolicy.create!(project_id: child.id, enabled: false, inherits_config: true)

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    # A lightweight row owns no configuration, so the form still shows the ancestor's — but the
    # tri-state, not the plain switch, owns the on/off decision, and it must show THIS project's.
    assert_select '#sla-policy-form'
    assert_select "input[name='sla_policy[enablement]'][value='disabled'][checked]"
    assert_select "input[type=checkbox][name='sla_policy[enabled]']", 0,
                  'the plain SLA-tracking switch would be a second, conflicting on/off control'
  end

  test "the tri-state control is not offered to a project that defines its own policy" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true)
    SlaPolicy.create!(project_id: child.id, enabled: true)

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select 'form#sla-enablement-form', 0
    assert_select '#sla-policy-form'
    # A self-defining project keeps the plain SLA-tracking switch.
    assert_select "input[type=checkbox][name='sla_policy[enabled]']", 1
  end

  test "a project with its own policy renders the editable form even though its parent also has one" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true) # parent's policy
    SlaPolicy.create!(project_id: child.id, enabled: true)    # child's own policy wins

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#sla-policy-form'
    assert_select 'button#sla-override-load', 0
  end

  test "a project with no policy anywhere shows the blank form with a helper hint, not the banner" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#sla-policy-form'
    assert_select 'button#sla-override-load', 0
  end

  def revert_delete_form_selector(project)
    "form[action='#{project_sla_policy_path(project)}'] input[name='_method'][value='delete']"
  end

  test "Revert to inherited policy is offered only when an ancestor also has a policy" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true) # ancestor policy exists
    SlaPolicy.create!(project_id: child.id, enabled: true)    # and child has its own

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_select revert_delete_form_selector(child)
  end

  test "Revert to inherited policy is NOT offered when no ancestor has a policy" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: child.id, enabled: true) # only the child has one

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_select revert_delete_form_selector(child), 0
  end

  # --- Step 5.1: the user allow-list ------------------------------------------------------------
  #
  # "A non-permitted role sees neither the tab nor the dashboard; an admin can grant access to a
  # chosen role and it takes effect." These cover the TAB half for users granted individually
  # rather than through a role — the case Redmine's role-only permission model cannot express.
  #
  # All of them log in as rhill (user 4): active, but a member of no project and holding no role.
  # Anything they can see here was granted by the allow-list and by nothing else.

  def list!(list, *user_ids)
    Setting.plugin_redmine_sla_compliance = {
      "sla_#{list}_user_ids" => user_ids.map(&:to_s)
    }
  end

  test "a listed manager gets the tab and both sections with no role at all" do
    @request.session[:user_id] = 4
    list!(:manager, 4)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }

    assert_response :success, 'a listed manager must be able to open the Settings page itself'
    assert_select '#tab-content-sla_policy .sla-plugin' do
      assert_select '#sla-policy-form'
      assert_select '#sla-notification-form'
    end
  end

  test "a listed viewer is dashboard-only and never sees the tab" do
    @request.session[:user_id] = 4
    list!(:viewer, 4)

    get :settings, params: { id: @project.identifier }

    # The viewer list grants the dashboard only, so the page hosting the tab stays closed to them.
    assert_response :forbidden
  end

  test "an unlisted user with no role sees neither the tab nor the Settings page" do
    @request.session[:user_id] = 4

    get :settings, params: { id: @project.identifier }
    assert_response :forbidden
  end

  test "granting a manager takes effect immediately, with no restart" do
    @request.session[:user_id] = 4

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :forbidden, 'precondition: not listed yet'

    list!(:manager, 4)
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success
    assert_select '#sla-policy-form'

    Setting.plugin_redmine_sla_compliance = {}
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :forbidden, 'revoking must apply just as immediately'
  end

  test "a listed manager sees only the SLA tab, not the rest of Project Settings" do
    # Claiming projects/settings for :edit_sla_policy opens the page, but every other tab is
    # still filtered by its own permission — a listed manager must not gain project admin.
    @request.session[:user_id] = 4
    list!(:manager, 4)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }

    assert_response :success
    # The positive assertion pins the selector form, so the two negatives below cannot pass
    # vacuously by naming an id that never exists.
    assert_select 'a#tab-sla_policy'
    assert_select 'a#tab-info', 0, 'must not gain the project Information tab'
    assert_select 'a#tab-members', 0, 'must not gain the Members tab'
  end

  test "a role granted only edit_sla_policy can reach the tab without edit_project" do
    # The role-based counterpart of the above: before Step 5.1, :edit_sla_policy alone was not
    # enough to open ProjectsController#settings, so the tab was unreachable for such a role.
    role = Role.create!(name: 'SLA Only', permissions: [:view_project, :edit_sla_policy])
    Member.create!(user_id: 4, project_id: @project.id, role_ids: [role.id])
    @request.session[:user_id] = 4

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }

    assert_response :success
    assert_select '#sla-policy-form'
    assert_select '#sla-notification-form', 0, 'edit_sla_policy alone must not open notifications'
  end
end
