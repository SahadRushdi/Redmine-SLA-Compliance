# frozen_string_literal: true

module Sla
  # Step 5.1 — resolves the user allow-list configured in Administration → SLA Compliance.
  #
  # Redmine grants permissions to ROLES, reached through project membership; it has no way to
  # express "this specific person can see SLA" without inventing a role and a membership for them.
  # Step 0.2 already declared the three permissions and every controller already enforces them, so
  # the role half of Step 5.1 needs nothing new. What this adds is the missing user-level grant.
  #
  # This class only answers "does the ALLOW-LIST grant it?" — it is never the whole answer. It is
  # called from RedmineSlaCompliance::Patches::UserPatch, and only once Redmine's own role check
  # has already said no, so roles/admins/modules keep behaving exactly as before. Hooking in at
  # `User#allowed_to?` (rather than at each of the plugin's own gate points) is what makes the
  # allow-list work uniformly for the project menu, `authorize`, the settings tab and the view
  # partials — several of those ask Redmine directly and never call plugin code.
  #
  # The allow-list is purely ADDITIVE — it can only ever grant the three SLA permissions, never
  # take anything away and never grant project visibility. A listed user still sees a project only
  # if Redmine already lets them see it, so a private project they aren't a member of stays
  # invisible.
  class AccessControl
    # Which allow-list grants which permission. Viewers get the dashboard, read-only; managers get
    # that PLUS the SLA Policy tab (policy form + notification settings).
    #
    # Keys are exactly the permissions declared in init.rb. A permission absent from this table is
    # never granted by the allow-list, so an unrelated permission — or a future SLA one someone
    # forgets to add here — fails closed rather than silently going to everyone on a list.
    GRANTED_BY = {
      view_sla_dashboard: %i[viewer manager],
      edit_sla_policy: %i[manager],
      manage_sla_notifications: %i[manager]
    }.freeze

    class << self
      # @param user    [User, nil]
      # @param action  [Symbol, Hash] a permission name, or Redmine's {controller:, action:} form
      # @param project [Project, nil]
      def granted?(user, action, project)
        return false if project.nil? || user.nil? || !user.logged?

        lists = GRANTED_BY[permission_for(action)]
        return false if lists.nil?

        # Cheap list membership first: `visible?` costs a query, and for the overwhelmingly common
        # case (nobody is listed at all) this returns false without touching the database.
        return false unless lists.any? { |list| listed?(user, list) }

        project.module_enabled?(:sla_compliance) && project.visible?(user)
      end

      private

      def listed?(user, list)
        PluginSettings.public_send(:"#{list}_user_ids").include?(user.id)
      end

      # Redmine asks `allowed_to?` two ways: with a permission name (`:edit_sla_policy`) and with a
      # controller/action Hash (menu items with a Hash url, and every `before_action :authorize`).
      # Both have to resolve to the same answer, or a listed user would be let into the controller
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
        @action_permissions ||= GRANTED_BY.keys.each_with_object({}) do |permission, map|
          Redmine::AccessControl.allowed_actions(permission).each do |controller_action|
            map[controller_action] ||= permission
          end
        end
      end
    end
  end
end
