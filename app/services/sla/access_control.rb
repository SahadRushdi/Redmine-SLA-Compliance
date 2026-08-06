# frozen_string_literal: true

module Sla
  # Step 5.1 — resolves the role-based SLA access configured in Administration → SLA Compliance.
  #
  # Redmine grants permissions to ROLES, reached through project membership. It can already
  # express "this role may see the SLA dashboard" — by ticking the plugin's three permissions on
  # that role — but doing so means editing every role, in every one of Redmine's role forms, and
  # keeping them in step by hand. This class replaces that with one instance-wide list: name the
  # roles that carry SLA access, and holding one of them is enough.
  #
  # This class only answers "does the ROLE LIST grant it?" — it is never the whole answer. It is
  # called from RedmineSlaCompliance::Patches::UserPatch, and only once Redmine's own role check
  # has already said no, so roles that DO tick the permissions, admins and disabled modules keep
  # behaving exactly as before. Hooking in at `User#allowed_to?` (rather than at each of the
  # plugin's own gate points) is what makes the grant work uniformly for the project menu,
  # `authorize`, the settings tab and the view partials — several of those ask Redmine directly
  # and never call plugin code.
  #
  # The grant is purely ADDITIVE — it can only ever grant the three SLA permissions, never take
  # anything away and never grant project visibility. Roles are held through membership, so a
  # user only ever gains SLA access on projects they are already a member of.
  #
  # HISTORY: until 2026-08-06 this resolved two per-USER allow-lists instead, with a viewer /
  # manager split (dashboard-only vs dashboard-plus-policy). Both lists and the split are gone:
  # access is now one list of roles, and a granted user gets all three permissions.
  class AccessControl
    # Exactly the permissions declared in init.rb. A permission absent from this list is never
    # granted here, so an unrelated permission — or a future SLA one someone forgets to add —
    # fails closed rather than silently going to every listed role.
    SLA_PERMISSIONS = %i[view_sla_dashboard edit_sla_policy manage_sla_notifications].freeze

    class << self
      # @param user    [User, nil]
      # @param action  [Symbol, Hash] a permission name, or Redmine's {controller:, action:} form
      # @param project [Project, nil]
      def granted?(user, action, project)
        return false if project.nil? || user.nil? || !user.logged?
        return false unless SLA_PERMISSIONS.include?(permission_for(action))

        # Cheapest check first: `roles_for_project` costs a query on its first call per project,
        # and for the overwhelmingly common case (no role is configured at all) this returns
        # false without touching the database.
        role_ids = PluginSettings.access_role_ids
        return false if role_ids.empty?
        return false unless holds_configured_role?(user, project, role_ids)

        project.module_enabled?(:sla_compliance) && project.visible?(user)
      end

      private

      # Redmine's own answer to "what is this person on this project?", so the plugin agrees with
      # the rest of the application about group-inherited memberships and archived projects.
      # User#roles_for_project memoises its membership lookup per project, so repeating this
      # across a menu render costs one query, not one per item.
      #
      # `builtin?` is the load-bearing half. For a PUBLIC project, roles_for_project answers with
      # the builtin Non-member (or Anonymous) role rather than an empty list — so without this
      # test, a settings hash naming role 1 would grant SLA access to every logged-in user on
      # every public project, member or not. The settings form only offers `Role.givable` and so
      # cannot produce that, but "the form wouldn't send it" is not a permission check.
      def holds_configured_role?(user, project, role_ids)
        user.roles_for_project(project).any? do |role|
          !role.builtin? && role_ids.include?(role.id)
        end
      end

      # Redmine asks `allowed_to?` two ways: with a permission name (`:edit_sla_policy`) and with a
      # controller/action Hash (menu items with a Hash url, and every `before_action :authorize`).
      # Both have to resolve to the same answer, or a granted user would be let into the controller
      # but never shown the link to it.
      def permission_for(action)
        return action.to_sym if action.is_a?(Symbol) || action.is_a?(String)
        return nil unless action.is_a?(Hash)

        action_permissions["#{action[:controller]}/#{action[:action]}"]
      end

      # Built from Redmine's own permission registry rather than hand-maintained, so the mapping
      # cannot drift from init.rb — including `projects/settings`, which :edit_sla_policy claims so
      # that holding it is enough to reach the SLA Policy tab.
      #
      # Memoised: this is consulted on permission checks that Redmine has already denied, which is
      # a hot path during menu rendering. Permissions are all registered at boot and never change
      # afterwards, and the first call happens while serving a request, so the map is complete.
      def action_permissions
        @action_permissions ||= SLA_PERMISSIONS.each_with_object({}) do |permission, map|
          Redmine::AccessControl.allowed_actions(permission).each do |controller_action|
            map[controller_action] ||= permission
          end
        end
      end
    end
  end
end
