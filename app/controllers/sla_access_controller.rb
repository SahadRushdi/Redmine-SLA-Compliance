# frozen_string_literal: true

# Step 5.1 — backs the user search on the two allow-list pickers in
# Administration → SLA Compliance. The lists themselves are stored in the plugin
# settings hash and saved by Redmine's own SettingsController#plugin, so this controller only
# has to answer "which users match what the admin is typing?".
#
# Admin-only, like the plugin's other two global lookups (SlaTargetOptionsController,
# SlaBusinessCalendarsController) — only an admin can reach the settings form that consumes it,
# so anything less would leak the user directory to non-admins.
class SlaAccessController < ApplicationController
  # Enough to pick from while typing; the picker narrows as the query gets more specific.
  RESULT_LIMIT = 20

  self.main_menu = false

  before_action :require_admin

  # GET /sla_access/users(?q=) -> [{ id:, name:, login:, mail: }, ...]
  # Reuses Redmine's own Principal.like scope, which already matches on login, first/last name
  # and email address, so "search users" behaves the same here as everywhere else in Redmine.
  #
  # Admins are never offered: they already bypass every SLA permission check (User#admin?
  # short-circuits UserPatch#allowed_to? via `return true if super`), so listing them would just
  # let an admin grant themselves a redundant, meaningless entry.
  def users
    scope = User.active.where(admin: false).sorted
    scope = scope.like(params[:q]) if params[:q].present?

    render json: scope.limit(RESULT_LIMIT).map { |user|
      { id: user.id, name: user.name, login: user.login, mail: user.mail }
    }
  end
end
