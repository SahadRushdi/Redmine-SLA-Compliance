# Splits a policy row's ENABLED DECISION from its CONFIGURATION, so a subproject can turn SLA on
# or off for itself without forking the whole policy (Global Rule 5's tri-state).
#
# Before this, the only way for a child project to say "SLA off here" was "Override for this
# project", which clones the ancestor's entire configuration into a child row — from that moment
# the child stops tracking the parent's coverage/targets/status-mapping changes.
#
# `inherits_config = false` (the default, and every pre-existing row) means "this row defines its
# own configuration" — exactly today's behavior, so upgrading changes nothing. `true` marks a
# LIGHTWEIGHT row that carries only `enabled`; SlaPolicy.effective_for keeps that row's on/off
# decision but resolves every other field from the nearest self-defining ancestor. Lightweight
# rows own no sla_definitions / sla_status_mappings.
class AddInheritsConfigToSlaPolicies < ActiveRecord::Migration[6.1]
  def up
    return if column_exists?(:sla_policies, :inherits_config)

    add_column :sla_policies, :inherits_config, :boolean, null: false, default: false
  end

  def down
    remove_column :sla_policies, :inherits_config, if_exists: true
  end
end
