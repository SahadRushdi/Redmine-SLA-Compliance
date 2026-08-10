# frozen_string_literal: true

# Home of the SLA Compliance admin module (Administration → SLA Compliance): the General and
# Access control sections, alongside the two lookup CRUD screens that share its shell and sidebar.
#
# WHY THIS EXISTS RATHER THAN A PLUGIN SETTINGS PARTIAL
# -----------------------------------------------------
# These settings used to render through Redmine's own SettingsController#plugin, reached by
# Administration → Plugins → Configure. That host made two things impossible:
#
#   1. Core declares `menu_item :plugins, :only => :plugin`, so while the settings page was open the
#      admin sidebar highlighted "Plugins", not "SLA Compliance" — the module's own entry could
#      never be the selected one on its own page.
#   2. Every plugin settings partial renders inside core's <form>, and forms cannot nest, which is
#      what forced the two lookups onto pages of their own in the first place.
#
# Owning the page fixes both: `menu_item :sla_compliance_settings` below marks the module's sidebar
# entry on every one of its pages, and this controller's own form has no core wrapper to fight.
#
# The settings themselves are unchanged — still one serialized hash under
# `Setting.plugin_redmine_sla_compliance`, still read by Sla::PluginSettings. Only who renders and
# saves them moved. `init.rb` correspondingly declares `settings default: {}` WITHOUT a `:partial`,
# which is exactly what makes Redmine::Plugin#configurable? false and drops the now-dead "Configure"
# link from the Plugins list (Setting.define_plugin_setting only needs `settings` to be present, so
# the stored hash and its default are unaffected).
class SlaSettingsController < ApplicationController
  layout 'admin'
  self.main_menu = false
  # Marks the "SLA Compliance" entry in the Administration sidebar as selected while any page of
  # this module is open (Redmine::MenuManager compares this against the admin_menu item's name).
  # The two lookup controllers declare the same item for the same reason.
  menu_item :sla_compliance_settings

  helper :sla_admin
  helper :sla_policies
  helper :sla_compliance

  before_action :require_admin

  # Scalar settings, and the SLA access roles, which post as an array of role ids.
  PERMITTED_SETTINGS = [].freeze
  PERMITTED_LIST_SETTINGS = { sla_access_role_ids: [] }.freeze

  # Keys of settings this module no longer has a field for. #update merges over the stored hash
  # (see there for why), which on its own would preserve a removed setting's last value forever —
  # so a retired key is dropped here instead, on the first save after the upgrade. Nothing reads
  # The user allow-lists were replaced by `sla_access_role_ids` on 2026-08-06. The unclassified
  # priority setting was removed when every active Redmine priority became directly configurable.
  RETIRED_SETTINGS = %w[sla_viewer_user_ids sla_manager_user_ids unclassified_priority_id
                        sweep_interval_minutes].freeze

  def show
    @settings = stored_settings
  end

  def update
    # Merged over the stored hash rather than replacing it: this form does not carry every key the
    # plugin may keep in there, and a blind replace would silently drop anything it doesn't render.
    Setting.plugin_redmine_sla_compliance =
      stored_settings.except(*RETIRED_SETTINGS).merge(settings_params)

    flash[:notice] = l(:notice_successful_update)
    # Back to the section the user was on — sla_admin.js keeps the hidden `section` field in step
    # with the open panel, so saving from another panel does not bounce you to General.
    redirect_to sla_settings_path(section: requested_section)
  end

  private

  def stored_settings
    (Setting.plugin_redmine_sla_compliance || {}).to_h
  end

  # The section to return to, or nil. Validated against the known panel keys rather than passed
  # through: `params[:section]` is unfiltered input, and handing url_for a nested hash there raised
  # ActionController::UnfilteredParameters (a 500) instead of redirecting. Nil-ing an unrecognised
  # value also matches what #show does with one, so the redirect and the render agree.
  def requested_section
    key = params[:section]
    key if key.is_a?(String) && SlaAdminHelper::PANEL_KEYS.include?(key)
  end

  # Always a plain Hash of permitted keys, never Parameters — `Setting` serializes this value
  # straight to YAML, so an ActionController::Parameters would be persisted as one.
  #
  # The `is_a?` guard is not ceremony: `params[:settings]` is whatever the client sent, and a
  # scalar (`?settings=x`) reaches `.permit` as a String and raises NoMethodError — a 500 rather
  # than the no-op it should be. Missing or malformed input means "change nothing", which the
  # empty hash gives when #update merges it.
  def settings_params
    raw = params[:settings]
    return {} unless raw.is_a?(ActionController::Parameters)

    raw.permit(*PERMITTED_SETTINGS, **PERMITTED_LIST_SETTINGS).to_h
  end
end
