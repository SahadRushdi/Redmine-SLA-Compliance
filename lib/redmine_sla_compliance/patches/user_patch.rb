# frozen_string_literal: true

module RedmineSlaCompliance
  module Patches
    # Step 5.1 — teaches Redmine's permission check about the plugin's SLA access roles.
    #
    # `User#allowed_to?` is the single question every gate in Redmine asks: `before_action
    # :authorize`, project menu items, settings tabs, and the plugin's own view partials all end up
    # here. It already carries one bypass of the role system (`return true if admin?`); the SLA
    # role list is a second, much narrower one — it says "holding this role is enough for the SLA
    # permissions, whether or not the role itself ticks them". Hooking in here — rather than at
    # each of the plugin's own gate points — is what makes that grant consistent: several of those
    # gates are core code that never calls plugin code, so a granted user would otherwise be let
    # into a controller but never shown a link to it, or be shown a tab on a page that 403s.
    #
    # Deliberately additive and fail-open-to-super: it only ever runs AFTER Redmine has already
    # denied the request, and it can only return true for the three SLA permissions on a project
    # the user is already a member of. Nothing it does can take away access anyone previously had,
    # which is what keeps the existing role-based tests meaningful.
    #
    # On cost (Global Rule 4 — don't slow Redmine): the added work on a denied check is an
    # `is_a?(Project)` test and one lookup in a memoised Hash, which returns nil for every
    # non-SLA permission. The database is only touched once roles are actually configured.
    module UserPatch
      def allowed_to?(action, context, options = {}, &block)
        return true if super

        # The grant is per-project by nature: roles are held through membership. The Array and
        # :global forms are left entirely to Redmine.
        return false unless context.is_a?(Project)

        Sla::AccessControl.granted?(self, action, context)
      end
    end
  end
end
