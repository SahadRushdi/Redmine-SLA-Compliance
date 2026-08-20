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
    notification = SlaNotificationSetting.create!(project_id: @project.id)
    recipient = @project.users.joins(:email_address).first
    notification.replace_recipient_user_ids!(:at_risk, [recipient.id])

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#tab-content-sla_policy .sla-plugin' do
      assert_select '#sla-policy-form'
      assert_select '#sla-notification-form'
      assert_select 'input#sla_policy_at_risk_threshold[value="85"]'
      assert_select "select[name='status_mappings[created][]'] option[selected][value='#{status_id}']"
      assert_select "#sla-definitions-rows-#{@project.trackers.first.id} " \
                    '[data-sla-target-cell][data-seconds="14400"]'
      assert_select "option[selected][value='#{recipient.id}']", text: /#{Regexp.escape(recipient.mail)}/
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
    assert_select "[data-sla-panel='exclusions']", 0
    assert_select '#sla-general-form button[type=submit]', 0,
                  'SLA Tracking autosaves and General must not expose a save button'
  end

  test "the requested section is the one rendered open" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'measurement' }
    assert_response :success

    assert_select "a[data-sla-section-link='measurement'].is-active"
    assert_select "[data-sla-panel='measurement']:not(.hidden)"
    assert_select "[data-sla-panel='general'].hidden"
  end

  test "Measurement Rules uses horizontal milestone controls and has no save button" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'measurement' }
    assert_response :success

    assert_select '#sla-measurement-form[data-measurement-url]' do
      assert_select '.lg\\:tw-grid-cols-3 [data-sla-measurement-role]', 3
      assert_select '[data-sla-measurement-attribute="first_response_rule"]', 3
      assert_select '[data-sla-measurement-attribute="at_risk_threshold"]', 1
      assert_select '[data-sla-measurement-attribute="stale_threshold_days"]', 1
      assert_select 'button[type=submit]', 0
    end
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
  LOCKED_PANELS = %w[targets measurement notifications].freeze

  test "the configuration sections are locked while SLA tracking is off" do
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

  # An inheriting project's on/off decision lives in the inherited toggle, not the plain switch,
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

    assert_select "input[type='checkbox'][name='sla_policy[enablement]'][data-sla-inherited-enablement][checked]", 1
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

  test "every active Redmine priority gets target controls without global priority configuration" do
    none = IssuePriority.create!(name: 'None', type: 'IssuePriority', position: 99)
    tracker_id = @project.trackers.sorted.first.id
    SlaPolicy.create!(project_id: @project.id, enabled: true, selected_tracker_ids: [tracker_id])
    # A stale value from an older plugin version must no longer hide that priority.
    Setting.plugin_redmine_sla_compliance = { 'unclassified_priority_id' => none.id.to_s }

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }
    assert_response :success

    assert_select '[data-sla-panel="targets"]' do
      IssuePriority.active.each do |priority|
        assert_select "[data-sla-target-cell][data-tracker-id='#{tracker_id}']" \
                      "[data-priority-id='#{priority.id}'][data-target-type='response']", 1
      end
      assert_select 'span', { text: 'Unclassified', count: 0 },
                    'the removed unclassified-priority label must not render'
    end
  ensure
    Setting.plugin_redmine_sla_compliance = {}
  end

  # --- Step 6.2a: the Stale threshold field -----------------------------------------------

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

  test "with nothing set anywhere the field is empty without helper text" do
    get_measurement_section

    assert_select "input[name='sla_policy[stale_threshold_days]'][value]", 0, 'no value, so it inherits'
    assert_select '#sla-stale-threshold-source', 0
  end

  test "a subproject shows which ancestor its inherited threshold comes from" do
    child = Project.find(5) # parent = @project (1)
    child.enable_module!(:sla_compliance)
    SlaPolicy.create!(project_id: @project.id, enabled: true, stale_threshold_days: 4)

    get_measurement_section(child)

    # The placeholder repeats it inside the empty box, so the number is visible where it is typed.
    assert_select "input[name='sla_policy[stale_threshold_days]'][placeholder=?]",
                  I18n.t(:label_sla_stale_threshold_placeholder_inherited, days: 4)
  end

  test "a project with its own value has no label below the field" do
    SlaPolicy.create!(project_id: @project.id, enabled: true, stale_threshold_days: 9)

    get_measurement_section

    assert_select '#sla-stale-threshold-source', 0
  end

  # The render half of the "I add a tracker, save, and it is gone" bug (the save half is covered in
  # SlaPoliciesControllerTest). A tracker the picker saved with NO targets set has no definitions to
  # be derived from, so before migration 009 nothing on this page knew it had ever been chosen.
  test "a saved tracker with no targets still renders its Priority Targets table" do
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true)
    targetless = @project.trackers.sorted.second
    policy.update!(selected_tracker_ids: [targetless.id])

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select "#sla-definitions-table-#{targetless.id}", 1
    assert_select "#sla-tracker-tabs [data-sla-tracker-tab='#{targetless.id}']", 1
  end

  # The Clone card reopens saying where the configuration came from, instead of on a blank picker
  # that leaves the provenance of a whole policy knowable only to whoever ran the clone.
  test "the clone picker preselects the project the policy was cloned from" do
    source_project = Project.find(2)
    source_project.enable_module!(:sla_compliance)
    member = Member.find_or_initialize_by(user_id: 2, project_id: source_project.id)
    member.role_ids = (member.role_ids + [@role.id]).uniq
    member.save!
    SlaPolicy.create!(project_id: source_project.id, enabled: true)
    SlaPolicy.create!(project_id: @project.id, enabled: true,
                      cloned_from_project_id: source_project.id)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select "#sla-clone-source option[selected][value='#{source_project.id}']", 1
    assert_select '.sla-plugin', text: /#{Regexp.escape(source_project.name)}/
  end

  test "the clone-from-project card renders in General below SLA Tracking, not in SLA Targets" do
    source_project = Project.find(2)
    source_project.enable_module!(:sla_compliance)
    member = Member.find_or_initialize_by(user_id: 2, project_id: source_project.id)
    member.role_ids = (member.role_ids + [@role.id]).uniq
    member.save!
    SlaPolicy.create!(project_id: source_project.id, enabled: true)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'general' }

    assert_response :success
    assert_select '[data-sla-panel="general"] #sla-clone-source', 1
    assert_select '[data-sla-panel="general"] #sla-clone-load', 1
    assert_select '[data-sla-panel="general"] label[for="sla-clone-source"]', 0
    assert_select '[data-sla-panel="general"] #sla-clone-source[aria-label=?]', I18n.t(:field_sla_clone_source)
    assert_select '[data-sla-panel="general"] #sla-clone-source.sla-clone-project-select', 1
    assert_select '#sla-clone-confirm-modal[role="dialog"][aria-modal="true"]', 1 do
      assert_select '[data-sla-clone-confirm]', text: I18n.t(:button_sla_load_policy), count: 1
      assert_select '[data-sla-clone-cancel]', text: I18n.t(:button_cancel), count: 1
    end
    assert_select '[data-sla-panel="targets"] #sla-clone-source', 0
  end

  test "data-driven policy dropdowns are ordered alphabetically" do
    SlaPolicy.create!(project_id: @project.id, enabled: true)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select "select[name='status_mappings[created][]']" do |selects|
      names = selects.first.css('option').map { |option| option.text.strip }
      assert_equal names.sort_by { |name| [name.downcase, name] }, names
    end

    assert_select '#sla-at-risk-recipients' do |selects|
      names = selects.first.css('option').map { |option| option.text.strip }
      assert_equal names.sort_by { |name| [name.downcase, name] }, names
    end
  end

  test "clone project options are ordered alphabetically regardless of project tree order" do
    %w[Zulu Alpha].each do |prefix|
      source = Project.create!(name: "#{prefix} Clone Source",
                               identifier: "#{prefix.downcase}-clone-source")
      source.enable_module!(:sla_compliance)
      Member.create!(project: source, principal: User.find(2), roles: [@role])
      SlaPolicy.create!(project: source, enabled: true)
    end

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success

    names = css_select('#sla-clone-source option').map { |option| option.text.strip }
    names.shift # prompt stays deliberately first
    assert_equal names.sort_by { |name| [name.downcase, name] }, names
  end

  test "every configured target type gets its own column, header and inline editor per priority" do
    tracker_id = @project.trackers.sorted.first.id
    SlaPolicy.create!(project_id: @project.id, enabled: true, selected_tracker_ids: [tracker_id])
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }
    assert_response :success

    priority   = IssuePriority.active.first
    SlaDefinition::TARGET_TYPES.each do |target_type|
      assert_select "[data-sla-target-cell][data-tracker-id='#{tracker_id}']" \
                    "[data-priority-id='#{priority.id}'][data-target-type='#{target_type}']", 1,
                    "#{target_type} must have an inline editor on every priority row"
      assert_select "[data-sla-target-cell][data-priority-id='#{priority.id}']" \
                    "[data-target-type='#{target_type}'] " \
                    'select[data-sla-target-unit][data-sla-select]', 1,
                    "#{target_type} must use the styled single-select component"
      # Title case from the i18n value, never an uppercase CSS transform (CLAUDE.md).
      assert_select "#sla-definitions-table-#{tracker_id} thead th",
                    text: I18n.t("label_sla_target_#{target_type}"), count: 1
    end
  end

  test "an unconfigured policy shows the tracker empty state and labeled add control" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select '#sla-definitions-trackers', 0
    assert_select '#sla-tracker-empty:not(.hidden) h3', text: I18n.t(:label_sla_no_configured_trackers), count: 1
    assert_select '#sla-tracker-empty [data-sla-add-tracker-toggle]', text: I18n.t(:button_sla_add_tracker), count: 1
    assert_select '#sla-tracker-content.hidden', 1
  end


  test "the add tracker control only lists enabled trackers not already selected" do
    selected = @project.trackers.sorted.first
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true,
                               selected_tracker_ids: [selected.id])

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select "[data-sla-add-tracker='#{selected.id}']", 0
    (@project.trackers - [selected]).each do |tracker|
      assert_select "[data-sla-add-tracker='#{tracker.id}']", text: tracker.name, count: 1
    end
    assert_select '#sla-tracker-tabs [data-sla-add-tracker-toggle]', text: I18n.t(:button_sla_add_tracker), count: 1
  end

  test "the add tracker control is hidden when every project tracker is selected" do
    SlaPolicy.create!(project_id: @project.id, enabled: true,
                      selected_tracker_ids: @project.trackers.ids)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select '[data-sla-add-tracker]', 0
    assert_select '[data-sla-add-tracker-toggle]:not(.hidden)', 0
  end

  test "selected trackers render as tabs with one target table visible" do
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true,
                               selected_tracker_ids: @project.trackers.first(2).map(&:id))
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select '#sla-tracker-tabs [data-sla-tracker-tab]', 2
    assert_select '#sla-tracker-tabs [aria-selected="true"]', 1
    assert_select '[data-sla-definition-table]:not(.hidden)', 1
    assert_select '[data-sla-definition-table].hidden', 1
  ensure
    policy&.destroy
  end

  test "clone sources exclude trackers removed from this project's selection" do
    selected_tracker, removed_tracker = @project.trackers.first(2)
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true,
                               selected_tracker_ids: [selected_tracker.id])
    [selected_tracker, removed_tracker].each do |tracker|
      policy.sla_definitions.create!(tracker_id: tracker.id, priority_id: IssuePriority.active.first.id,
                                     response_seconds: 3600)
    end

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select "#sla-clone-tracker-source option[value='#{selected_tracker.id}']", 1
    assert_select "#sla-clone-tracker-source option[value='#{removed_tracker.id}']", 0
  ensure
    policy&.destroy
  end

  test "tracker clone uses the Clone Tracker button and centered confirmation modal" do
    trackers = @project.trackers.first(2)
    policy = SlaPolicy.create!(project_id: @project.id, enabled: true,
                               selected_tracker_ids: trackers.map(&:id))
    policy.sla_definitions.create!(tracker_id: trackers.first.id,
                                   priority_id: IssuePriority.active.first.id,
                                   response_seconds: 3600)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select '#sla-clone-tracker-button', text: I18n.t(:button_sla_clone_tracker), count: 1
    assert_select '#sla-clone-tracker-modal[role="dialog"][aria-modal="true"]', 1 do
      assert_select '.tw-text-center', 1
      assert_select '[data-sla-clone-tracker-confirm]', text: I18n.t(:button_sla_clone_tracker), count: 1
      assert_select '[data-sla-clone-tracker-cancel]', text: I18n.t(:button_cancel), count: 1
    end
  end

  test "SLA Targets has only a checkbox-enabled standalone Recalculate action" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select '[data-sla-panel="targets"] [data-sla-targets-save]', 0
    assert_select '[data-sla-panel="targets"] button[type="submit"]', 0
    assert_select '[data-sla-panel="targets"] input[name="recalculate"]', 1
    assert_select '[data-sla-panel="targets"] [data-sla-recalculate-button][disabled]',
                  text: I18n.t(:button_sla_recalculate), count: 1
  end

  # A disabled alert card collapses to just its switch, but its fields stay in the DOM and keep
  # posting — otherwise turning an alert off and on again would silently drop the recipients the
  # project had already saved.
  test "a disabled alert card hides its detail fields without dropping them from the form" do
    notification = SlaNotificationSetting.create!(project_id: @project.id, at_risk_email_enabled: false)
    recipient = @project.users.joins(:email_address).first
    notification.replace_recipient_user_ids!(:at_risk, [recipient.id])

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'notifications' }
    assert_response :success

    assert_select '[data-sla-reveal="at-risk-email"].hidden'
    assert_select '#sla-notification-form select#sla-at-risk-recipients' do
      assert_select "option[selected][value='#{recipient.id}']", text: /#{Regexp.escape(recipient.mail)}/
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

  test "notifications autosave every control and render no dedicated save button" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'notifications' }

    assert_response :success
    assert_select '#sla-notification-form[data-sla-notification-autosave]' do
    assert_select '[data-sla-notification-field]', 6
      assert_select '[data-sla-notification-status]', 1
      assert_select 'button[type=submit]', 0
      assert_select 'input[type=submit]', 0
    end
  end

  test "each inactive project channel identifies its effective fallback source" do
    global = SlaNotificationSetting.global_for_form
    global.google_chat_webhook = 'https://chat.example.test/global'
    global.stale_email_enabled = true
    global.save!
    parent = Project.find(3).parent
    SlaPolicy.create!(project_id: parent.id, enabled: true)
    SlaNotificationSetting.create!(project_id: parent.id, at_risk_email_enabled: true)
    @project = Project.find(3)
    @project.enable_module!(:sla_compliance)
    grant_child_access(@project)

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'notifications' }

    assert_response :success
    assert_select '[data-sla-notification-fallback="admin"]', 2
    assert_select '[data-sla-notification-fallback="parent"]',
                  { count: 1, text: /#{Regexp.escape(parent.name)}/ }
    assert_select '[data-sla-notification-fallback="admin"] a', 0,
                  'non-admin project managers must not receive an admin settings link'
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
    %w[general measurement targets notifications].each do |key|
      assert_select "a[data-sla-section-link='#{key}']"
    end
    assert_select '#sla-policy-form'
    # ...and every control carries the INHERITED value, so nothing can be saved from a field the
    # user was never shown.
    assert_select 'input#sla_policy_at_risk_threshold[value="85"]'
    assert_select "select[name='status_mappings[created][]'] option[selected][value='#{status_id}']"
    assert_select "#sla-definitions-rows-#{child.trackers.first.id} " \
                  '[data-sla-target-cell][data-seconds="14400"]'
    assert_select 'button#sla-override-load', 0, 'the form itself is the override now'
  end

  # --- Toggle SLA on/off above the inherited (pre-filled) sections -----------------------------

  test "the inherited policy offers one toggle reflecting the inherited state" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: true)

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select '#sla-enablement-form' do
      assert_select "input[type='checkbox'][name='sla_policy[enablement]'][data-sla-inherited-enablement][checked]", 1
      assert_select "input[type='radio'][name='sla_policy[enablement]']", 0
      assert_select 'span', text: I18n.t(:label_sla_enablement_inherited_from, project: @project.name)
      assert_select '[data-tracking-url]', 1
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
    # inherited toggle, not the plain policy switch, owns the on/off decision and shows THIS project's.
    assert_select '#sla-policy-form'
    assert_select "input[type='checkbox'][name='sla_policy[enablement]'][data-sla-inherited-enablement]:not([checked])", 1
    assert_select "input[type='radio'][name='sla_policy[enablement]']", 0
    assert_select "input[type=checkbox][name='sla_policy[enabled]']", 0,
                  'the plain SLA-tracking switch would be a second, conflicting on/off control'
  end

  test "an inherited toggle is off when the ancestor is off" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: @project.id, enabled: false)

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_response :success

    assert_select "input[type='checkbox'][name='sla_policy[enablement]'][data-sla-inherited-enablement]:not([checked])", 1
  end

  test "the inherited toggle is not offered to a project that defines its own policy" do
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

  test "SLA Targets renders the scoped historical recalculation progress component" do
    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }
    assert_response :success

    assert_select '[data-sla-panel="targets"]' do
      assert_select '#sla-recalculation-progress[data-sla-recalculation-progress][data-status="idle"]', 1 do
        assert_select '[data-status-url*="recalculation_status"]', 1
        assert_select '[role="progressbar"][aria-valuemin="0"][aria-valuemax="100"]', 1
        assert_select '[data-sla-recalculation-status][aria-live="polite"]', 1
        assert_select '[data-sla-recalculation-fill]', 1
      end
    end
  end

  test "tracker removal modal uses the centered remove copy and action" do
    tracker = @project.trackers.first
    SlaPolicy.create!(project_id: @project.id, enabled: true, selected_tracker_ids: [tracker.id])

    get :settings, params: { id: @project.identifier, tab: 'sla_policy', section: 'targets' }

    assert_response :success
    assert_select '#sla-remove-tracker-modal [data-sla-remove-message]', 1
    assert_select '#sla-remove-tracker-modal .tw-text-center', 1
    assert_select '#sla-remove-tracker-modal [data-sla-remove-confirm]', text: I18n.t(:button_sla_remove), count: 1
    assert_select '#sla-remove-tracker-modal [data-sla-remove-cancel]', text: I18n.t(:button_cancel), count: 1
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
    assert_select 'button[data-sla-revert-open].tw-bg-red-600',
                  text: I18n.t(:button_sla_revert_to_inherited), count: 1
    assert_select '#sla-revert-policy-modal[role="dialog"][aria-modal="true"][aria-hidden="true"]', 1 do
      assert_select '#sla-revert-policy-title', text: I18n.t(:label_sla_revert_confirm)
      assert_select '#sla-revert-policy-description',
                    text: I18n.t(:text_sla_revert_confirm, project: @project.name)
      assert_select 'button[data-sla-revert-cancel]', text: I18n.t(:button_cancel), count: 1
      assert_select 'form .tw-bg-red-600', count: 1
    end
    assert_select '[data-sla-revert-open][data-confirm]', 0
  end

  test "Revert to inherited policy is NOT offered when no ancestor has a policy" do
    child = Project.find(5)
    grant_child_access(child)
    SlaPolicy.create!(project_id: child.id, enabled: true) # only the child has one

    get :settings, params: { id: child.identifier, tab: 'sla_policy' }
    assert_select revert_delete_form_selector(child), 0
  end

  # --- Step 5.1: the SLA access roles -----------------------------------------------------------
  #
  # "A non-permitted role sees neither the tab nor the dashboard; an admin can grant access to a
  # chosen role and it takes effect." These cover the TAB half of that, for a role that ticks NO
  # SLA permission of its own and is granted purely by being named in the plugin settings.
  #
  # All of them log in as rhill (user 4): active, and a member of no project until a test makes
  # them one. Anything they can see here was granted by that membership plus the role list.

  def sla_role!
    @sla_role ||= Role.create!(name: 'SLA Access Test Role', permissions: [])
  end

  def member!(project = @project)
    Member.create!(principal: User.find(4), project: project, roles: [sla_role!])
  end

  def configure_sla_role!
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => [sla_role!.id.to_s] }
  end

  def grant!(project = @project)
    member!(project)
    configure_sla_role!
  end

  test "a member holding an SLA access role gets the tab and both sections" do
    @request.session[:user_id] = 4
    grant!

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }

    assert_response :success, 'a granted member must be able to open the Settings page itself'
    assert_select '#tab-content-sla_policy .sla-plugin' do
      assert_select '#sla-policy-form'
      assert_select '#sla-notification-form'
    end
  end

  test "holding a role that is not an SLA access role never sees the tab" do
    @request.session[:user_id] = 4
    member! # the membership without naming the role in the settings

    get :settings, params: { id: @project.identifier }

    # The role ticks no permission of its own, so until it is named in the settings it opens
    # nothing — not the tab, and not the page that hosts it.
    assert_response :forbidden
  end

  test "a user with no role at all sees neither the tab nor the Settings page" do
    @request.session[:user_id] = 4

    get :settings, params: { id: @project.identifier }
    assert_response :forbidden
  end

  test "granting a role takes effect immediately, with no restart" do
    @request.session[:user_id] = 4
    member!

    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :forbidden, 'precondition: the role is not named in the settings yet'

    configure_sla_role!
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :success
    assert_select '#sla-policy-form'

    Setting.plugin_redmine_sla_compliance = {}
    get :settings, params: { id: @project.identifier, tab: 'sla_policy' }
    assert_response :forbidden, 'revoking must apply just as immediately'
  end

  test "a granted member sees only the SLA tab, not the rest of Project Settings" do
    # Claiming projects/settings for :edit_sla_policy opens the page, but every other tab is
    # still filtered by its own permission — a granted member must not gain project admin.
    @request.session[:user_id] = 4
    grant!

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
