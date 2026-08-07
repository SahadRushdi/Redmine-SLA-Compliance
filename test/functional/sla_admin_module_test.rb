# frozen_string_literal: true

require_relative '../test_helper'

# Shared assertions for the SLA Compliance ADMIN MODULE shell (Administration → SLA Compliance).
#
# The three admin screens — the settings page and the two lookup CRUD pages — used to be
# disconnected pages joined only by inline text links, hosted partly by Redmine's own
# SettingsController, with the browser's Back button as the only way back. They are now one module
# behind one persistent sidebar (SlaAdminHelper), under one Administration sidebar entry. What makes
# that true is structural, not cosmetic, so it is asserted here rather than left to a visual check.
#
# Three controllers host those pages, hence a module of assertions included by each rather than the
# same block copied three times.
module SlaAdminModuleAssertions
  # Where each sidebar entry points, in the order SlaAdminHelper::SECTIONS declares them. Written
  # out here (not derived from the helper) so a change to either side has to be made deliberately
  # in both places instead of the test agreeing with the code by construction.
  def sla_section_hrefs
    {
      'general' => sla_settings_path(section: 'general'),
      'target_options' => sla_target_options_path,
      'business_calendars' => sla_business_calendars_path
    }
  end

  # Every page of the module must render the whole sidebar and mark exactly the section it is on.
  # This is what silently regresses if a page stops rendering through sla_admin/_shell.
  def assert_module_shell(active_key)
    hrefs = sla_section_hrefs

    assert_select '.sla-admin-module', 1, 'the page must render inside the admin module shell'
    assert_select 'nav .sla-section-link', hrefs.size,
                  'every section must be reachable from every page of the module'
    hrefs.each_value { |href| assert_select 'nav .sla-section-link[href=?]', href, 1 }

    assert_select 'nav .sla-section-link.is-active', 1, 'exactly one entry may be active'
    assert_select 'nav .sla-section-link.is-active[href=?][aria-current=?]',
                  hrefs.fetch(active_key), 'page'

    # A link may only be marked for in-place panel switching when THIS page renders that panel.
    # Otherwise sla_admin.js preventDefault()s a click it cannot honour and the sidebar goes dead —
    # the page never navigates and two entries end up looking active at once.
    # css_select, not assert_select-with-a-block: the block form asserts at least one match (wrong
    # on the lookup pages, where zero is correct) and scopes any nested assert_select to the matched
    # element rather than the document.
    css_select('[data-sla-admin-section]').each do |link|
      key = link['data-sla-admin-section']
      assert_select '[data-sla-admin-panel=?]', key, 1,
                    "#{key} is marked as a panel switch but has no panel on this page"
    end

    # And the Administration sidebar itself must mark "SLA Compliance", not "Plugins". Redmine
    # marks an admin_menu item selected when its NAME matches the controller's `menu_item`, and
    # renders the dasherized name as a CSS class — so this is the whole mechanism, asserted on
    # every page of the module at once.
    assert_select '#admin-menu a.sla-compliance-settings.selected', 1,
                  'the module must own the Administration sidebar entry on all of its pages'
  end
end

# --- Settings page: the General and Access control panels ---------------------------------------
class SlaAdminSettingsPageTest < ActionController::TestCase
  tests SlaSettingsController
  include SlaAdminModuleAssertions

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :enumerations

  setup do
    @request.session[:user_id] = 1 # admin
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  def get_page(params = {})
    get :show, params: params
  end

  test "the settings page renders the module shell" do
    get_page
    assert_response :success
    assert_module_shell('general')
  end

  test "every panel section is in the DOM, with only the current one visible" do
    # Not merely a rendering detail: one form spans every panel and posts every field on the page
    # in one submit, so a panel that was omitted rather than hidden would post nothing and its
    # settings would be cleared on the next save. General has been the only panel since Access
    # control was folded into it (2026-08-06); the assertion is written against the helper so a
    # second panel coming back is covered without editing it.
    get_page

    assert_select '[data-sla-admin-panel]', SlaAdminHelper::PANEL_KEYS.size
    assert_select '[data-sla-admin-panel=?]:not(.hidden)', 'general'
  end

  test "the requested section opens" do
    get_page(section: 'general')

    assert_module_shell('general')
    assert_select '[data-sla-admin-panel=?]:not(.hidden)', 'general'
  end

  test "an unknown section falls back to the first panel rather than showing nothing" do
    get_page(section: 'nonsense')

    assert_module_shell('general')
    assert_select '[data-sla-admin-panel=?]:not(.hidden)', 'general'
  end

  test "only the panel sections are intercepted by the section-switching script" do
    # The two lookup sections are separate resources at their own URLs; tagging their links
    # data-sla-admin-section would make sla_admin.js preventDefault a navigation that has no panel
    # to switch to, stranding the user on the settings page.
    get_page

    assert_select '.sla-section-link[data-sla-admin-section]', SlaAdminHelper::PANEL_KEYS.size
    assert_select '.sla-section-link[href=?][data-sla-admin-section]', sla_target_options_path, 0
    assert_select '.sla-section-link[href=?][data-sla-admin-section]',
                  sla_business_calendars_path, 0
  end

  test "the General panel keeps every settings field name the save path depends on" do
    # Renaming any of these would silently stop the setting being persisted: SlaSettingsController
    # permits them by name and merges them into Setting.plugin_redmine_sla_compliance.
    get_page

    assert_select 'input[name=?]', 'settings[sweep_interval_minutes]'
    assert_select 'select[name=?]', 'settings[unclassified_priority_id]'
    # Removed on request, together with the fallback it fed — a Google Chat webhook is a
    # per-project setting only now.
    assert_select 'input[name=?]', 'settings[google_chat_webhook]', 0
  end

  test "malformed input is a no-op, not a 500" do
    # `params[:settings]` and `params[:section]` are whatever the client sent. A scalar `settings`
    # reached .permit as a String (NoMethodError), and a nested-hash `section` reached url_for as
    # unpermitted Parameters (ActionController::UnfilteredParameters) — both 500s.
    Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => '7' }

    patch :update, params: { settings: 'not-a-hash' }
    assert_response :redirect

    patch :update, params: { settings: {}, section: { evil: 'x' } }
    assert_response :redirect
    assert_redirected_to sla_settings_path

    patch :update
    assert_response :redirect

    assert_equal '7', Setting.plugin_redmine_sla_compliance['sweep_interval_minutes'],
                 'none of those may have altered a stored setting'
  end

  test "an unknown section is dropped from the post-save redirect" do
    patch :update, params: { settings: {}, section: 'nonsense' }

    assert_redirected_to sla_settings_path
  end

  test "saving from a panel returns to that panel" do
    patch :update, params: { settings: {}, section: 'general' }

    assert_redirected_to sla_settings_path(section: 'general')
  end

  test "the module script and the scoped stylesheet reach the page" do
    get_page

    assert_select 'script[src*=?]', 'sla_admin', 1
    assert_select 'link[href*=?]', 'tailwind.output', 1
  end
end

# --- Target options -----------------------------------------------------------------------------
class SlaAdminTargetOptionsPagesTest < ActionController::TestCase
  tests SlaTargetOptionsController
  include SlaAdminModuleAssertions

  fixtures :users, :email_addresses

  setup { @request.session[:user_id] = 1 } # admin

  def make_option(attrs = {})
    SlaTargetOption.create!({ target_type: 'response', code: '4h', label: '4 hours',
                              seconds: 14_400, position: 1 }.merge(attrs))
  end

  test "the list renders the module shell with its own section active" do
    make_option
    get :index

    assert_response :success
    assert_module_shell('target_options')
  end

  test "the sidebar links out of this page are plain navigations" do
    # The regression: with data-sla-admin-section emitted here too, clicking General or Access
    # control from this page was cancelled by sla_admin.js and nothing happened.
    get :index

    assert_select '[data-sla-admin-panel]', 0, 'this page renders no panels'
    assert_select '[data-sla-admin-section]', 0,
                  'so no sidebar link here may be marked for in-place panel switching'
    assert_select '.sla-section-link[href=?]', sla_settings_path(section: 'general'), 1
  end

  test "an empty list shows an empty state with the create action, not a bare no-data line" do
    get :index

    assert_response :success
    assert_select '.sla-admin-rows tr', 0
    assert_select 'p', text: I18n.t(:label_sla_no_target_options_yet)
    assert_select 'a[href=?]', new_sla_target_option_path
  end

  # --- Column sorting (client-side) ---------------------------------------------------------------
  # The sorting itself runs in the browser (sla_admin.js + sla_table_sort.js), so what is asserted
  # here is the contract the markup owes that script: which columns are sortable, what type each
  # sorts as, and the sort value behind a cell whose text is not what you sort by.

  test "every named column carries a sort hook, and the actions column does not" do
    make_option
    get :index

    %w[target_type label duration basis].each do |key|
      assert_select "thead th[data-sla-sort=?]", key, 1, "#{key} must be sortable"
    end
    # Four named columns plus the unnamed row-actions column, which must not be sortable.
    # Code and Position are no longer columns: neither is editable anywhere any more.
    assert_select 'thead th', 5
    assert_select 'thead th[data-sla-sort]', 4
    %w[code position].each do |key|
      assert_select "thead th[data-sla-sort=?]", key, 0, "#{key} is no longer a column"
    end
    assert_select 'table[data-sla-sortable-table]', 1, 'the script binds on this attribute'
  end

  test "each sortable header carries the icon slot the script paints" do
    make_option
    get :index

    # Same hook and the same starting state as the dashboard's ticket detail table.
    assert_select 'thead th[data-sla-sort] .sla-sort-icon', 4
    assert_select 'thead th[data-sla-sort][aria-sort=?]', 'none', 4
  end

  test "the numeric columns declare themselves numeric" do
    # Without this they sort as text, where "10" lands before "9".
    make_option
    get :index

    assert_select "thead th[data-sla-sort=?][data-sla-sort-type=?]", 'duration', 'number'
    assert_select "thead th[data-sla-sort=?][data-sla-sort-type=?]", 'label', 'text'
  end

  test "duration sorts by raw seconds, not by the text it displays" do
    # The cell reads "4h"; sorting it as text would order it against "48 Hours" alphabetically.
    make_option(seconds: 14_400)
    get :index

    assert_select "td[data-sla-sort-value=?]", '14400', 1
  end

  test "a Best Effort row carries no sort value, so it sorts last either way" do
    # Blanks sort last in both directions (sla_table_sort.js). A target with no deadline is
    # neither the shortest nor the longest, and must not jump ends as the arrow flips.
    SlaTargetOption.delete_all
    make_option(code: 'be', label: 'Best Effort', best_effort: true, seconds: nil)
    get :index

    assert_select "td[data-sla-sort-value='']", 1
  end

  test "no sorting round trip is offered" do
    # Client-side means the headers are click targets, not links: a header <a> would navigate and
    # a ?sort= param would be ignored by the controller, which orders the list one fixed way.
    make_option
    get :index

    assert_select 'thead th a', 0
    assert_select 'thead th[data-sla-sort]' do |headers|
      headers.each { |th| assert_nil th['href'] }
    end
  end

  test "each row offers edit and delete" do
    option = make_option
    get :index

    assert_select '.sla-admin-row-action[href=?]', edit_sla_target_option_path(option)
    assert_select '.sla-admin-row-action[href=?][data-method=?]',
                  sla_target_option_path(option), 'delete'
  end

  test "the form keeps the record's own param names and offers a way back" do
    get :new

    assert_module_shell('target_options')
    assert_select 'select[name=?]', 'sla_target_option[target_type]'
    assert_select 'input[name=?]', 'sla_target_option[label]'
    assert_select 'select[name=?]', 'sla_target_option[basis]'
    # The duration is entered as an amount + a unit and multiplied into `seconds` by the model.
    assert_select 'input[name=?]', 'sla_target_option[duration_amount]'
    assert_select 'select[name=?]', 'sla_target_option[duration_unit]'
    # Removed from the form: code is derived from the label, position keeps what the row has,
    # and nobody types a duration in seconds any more.
    assert_select 'input[name=?]', 'sla_target_option[code]', 0
    assert_select 'input[name=?]', 'sla_target_option[position]', 0
    assert_select 'input[name=?]', 'sla_target_option[seconds]', 0
    # Best Effort is a switch now; it still posts the checkbox pair the controller casts.
    assert_select 'input[type=hidden][name=?][value=?]', 'sla_target_option[best_effort]', '0'
    assert_select 'input[type=checkbox][name=?]', 'sla_target_option[best_effort]'
    # Cancel goes to the list, not history.back().
    assert_select 'a[href=?]', sla_target_options_path
  end

  test "the duration field is hidden on a Best Effort option" do
    # A Best Effort option must have no seconds at all, so the field is revealed only while the
    # switch is off (sla_admin.js keeps this in step client-side).
    option = make_option(code: 'be', label: 'Best Effort', best_effort: true, seconds: nil)
    get :edit, params: { id: option.id }

    assert_select '[data-sla-reveal=?].hidden', 'duration'
  end
end

# --- Business calendars ---------------------------------------------------------------------------
class SlaAdminBusinessCalendarsPagesTest < ActionController::TestCase
  tests SlaBusinessCalendarsController
  include SlaAdminModuleAssertions

  fixtures :users, :email_addresses, :projects

  setup { @request.session[:user_id] = 1 } # admin

  def make_calendar(attrs = {})
    SlaBusinessCalendar.create!({ name: 'Standard week', working_days: [1, 2, 3, 4, 5],
                                  work_start_time: '09:00',
                                  work_end_time: '17:00' }.merge(attrs))
  end

  test "the list renders the module shell with its own section active" do
    make_calendar
    get :index

    assert_response :success
    assert_module_shell('business_calendars')
  end

  test "the sidebar links out of this page are plain navigations" do
    get :index

    assert_select '[data-sla-admin-panel]', 0, 'this page renders no panels'
    assert_select '[data-sla-admin-section]', 0,
                  'so no sidebar link here may be marked for in-place panel switching'
    assert_select '.sla-section-link[href=?]', sla_settings_path(section: 'general'), 1
  end

  test "an empty list shows an empty state, not a warning banner" do
    get :index

    assert_response :success
    assert_select '.sla-admin-rows tr', 0
    assert_select 'p', text: I18n.t(:label_sla_no_business_calendars_yet)
    assert_select 'a[href=?]', new_sla_business_calendar_path
  end

  test "the list shows all seven days, marking only the working ones" do
    make_calendar(working_days: [1, 2, 3, 4, 5])
    get :index

    assert_select '.sla-admin-day-chip', 7
    assert_select '.sla-admin-day-chip.is-on', 5
  end

  test "holidays render as chips, pre-selected so a no-JS submit cannot clear them" do
    calendar = make_calendar(holidays: %w[2026-12-25 2026-01-01])
    get :edit, params: { id: calendar.id }

    assert_select 'select[name=?][multiple]', 'sla_business_calendar[holidays][]'
    assert_select 'select[name=?] option[selected]', 'sla_business_calendar[holidays][]', 2
    # Sentinel: without it, removing the last chip would post no holidays key at all and the
    # stored list would survive a deliberate clear.
    assert_select 'input[type=hidden][name=?][value=?]', 'sla_business_calendar[holidays][]', ''
  end

  test "working days stay the same checkboxes, only presented as tiles" do
    calendar = make_calendar(working_days: [1, 5])
    get :edit, params: { id: calendar.id }

    assert_select 'input[type=checkbox][name=?]', 'sla_business_calendar[working_days][]', 7
    assert_select 'input[type=checkbox][name=?][checked]',
                  'sla_business_calendar[working_days][]', 2
  end

  test "an emptied chip list clears the stored holidays" do
    # End-to-end proof that the sentinel above does its job through the controller's params.
    calendar = make_calendar(holidays: %w[2026-12-25])

    put :update, params: { id: calendar.id,
                           sla_business_calendar: { name: calendar.name, holidays: [''] } }

    assert_redirected_to sla_business_calendars_path
    assert_equal [], calendar.reload.holidays
  end

  test "chip-posted holidays are stored, and win over the older textarea shape" do
    calendar = make_calendar

    put :update, params: { id: calendar.id,
                           sla_business_calendar: { name: calendar.name,
                                                    holidays: ['', '2026-12-25', '2026-01-01'],
                                                    holidays_text: '1999-01-01' } }

    assert_equal %w[2026-12-25 2026-01-01], calendar.reload.holidays
  end
end

# --- The old way in is gone ---------------------------------------------------------------------
# `init.rb` declares `settings default: {}` with no `:partial`, which is what makes
# Redmine::Plugin#configurable? false. Both consequences are asserted, because dropping the key is
# easy to undo by accident and the module would then have two entrances, only one of which can
# highlight the right sidebar entry.

class SlaAdminNoConfigureLinkTest < ActionController::TestCase
  tests AdminController

  fixtures :users, :email_addresses

  setup { @request.session[:user_id] = 1 } # admin

  test "the Plugins list offers no Configure link for this plugin" do
    assert_not Redmine::Plugin.find('redmine_sla_compliance').configurable?,
               'declaring a settings :partial again would restore the duplicate entrance'

    get :plugins

    assert_response :success
    assert_select 'a[href=?]', plugin_settings_path('redmine_sla_compliance'), 0
  end
end

class SlaAdminNoConfigurePageTest < ActionController::TestCase
  tests SettingsController

  fixtures :users, :email_addresses

  setup { @request.session[:user_id] = 1 } # admin

  test "the old plugin settings URL is not found" do
    get :plugin, params: { id: 'redmine_sla_compliance' }

    assert_response :not_found
  end
end
