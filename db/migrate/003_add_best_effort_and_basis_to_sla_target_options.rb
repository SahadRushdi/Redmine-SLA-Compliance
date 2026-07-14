# Phase 4 hardening (B4):
#
# (a) "Best Effort" (a valid Resolution target per the spec — "never breaches") was impossible to
#     configure: `sla_target_options.seconds` was a required field, so a no-numeric-deadline
#     target couldn't be created at all. `best_effort` marks a lookup row as having no duration;
#     `seconds` becomes optional (and is forced blank) for those rows.
#
# (b) Duration options like "1 Business Day" are only unambiguous when the POLICY they're used on
#     measures elapsed time in working seconds (Coverage Hours = Business Hours) — under 24x7x365
#     coverage the same stored seconds value is silently read as calendar time, giving a
#     numerically wrong answer with no warning. `basis` records which the admin intended
#     ('calendar' = wall-clock seconds, the only kind that already existed; 'business' = working
#     seconds, only meaningful under Business Hours coverage) so SlaDefinition can validate the
#     combination and reject it before it produces a silently wrong dashboard number.
#
# `sla_definitions` needs its own per-milestone best_effort flags (not just a reference back to
# sla_target_options) to stay consistent with the existing "snapshot the chosen value, don't
# reference the lookup by id" design (see SlaDefinition's own comment) — a definition must keep
# working even if the admin later edits or removes the lookup row it was chosen from.
class AddBestEffortAndBasisToSlaTargetOptions < ActiveRecord::Migration[6.1]
  def up
    unless column_exists?(:sla_target_options, :best_effort)
      add_column :sla_target_options, :best_effort, :boolean, null: false, default: false
    end
    unless column_exists?(:sla_target_options, :basis)
      add_column :sla_target_options, :basis, :string, limit: 20, null: false, default: 'calendar'
    end
    change_column_null :sla_target_options, :seconds, true

    %w[response workaround resolution].each do |type|
      column = :"#{type}_best_effort"
      next if column_exists?(:sla_definitions, column)

      add_column :sla_definitions, column, :boolean, null: false, default: false
    end
  end

  def down
    %w[response workaround resolution].each do |type|
      remove_column :sla_definitions, :"#{type}_best_effort", if_exists: true
    end

    # A best_effort row has no seconds value; force one before restoring NOT NULL so `down` never
    # leaves the table in a state the pre-B4 schema couldn't represent.
    execute "UPDATE sla_target_options SET seconds = 1 WHERE seconds IS NULL"
    change_column_null :sla_target_options, :seconds, false
    remove_column :sla_target_options, :basis, if_exists: true
    remove_column :sla_target_options, :best_effort, if_exists: true
  end
end
