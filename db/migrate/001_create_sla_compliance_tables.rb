# Creates all Phase 1 tables for the SLA Compliance plugin.
#
# Design rules (Global Rules 1-3):
#   * Every reference to a Redmine object is stored as an INTEGER ID (project_id, issue_id,
#     tracker_id, priority_id, status_id) — never a label string.
#   * `role`, `primary_state`, `coverage_hours`, `first_response_rule`, `target_type`, etc. are
#     PLUGIN-internal enum values (state-machine roles / modes), not Redmine domain data — so they
#     are safe to name here.
#   * Foreign keys are added only for intra-plugin relationships and the owning project, so a
#     project delete cascades. We deliberately do NOT add DB FKs on issue_id/tracker_id/priority_id/
#     status_id: sla_results is a cache that may briefly outlive the objects it references, and we
#     must never let plugin constraints block Redmine deleting its own records.
class CreateSlaComplianceTables < ActiveRecord::Migration[6.1]
  def up
    # Business calendars (admin-managed; referenced by policies). Standalone lookup.
    unless table_exists?(:sla_business_calendars)
      create_table :sla_business_calendars do |t|
        t.string  :name, null: false, limit: 255
        t.text    :working_days   # serialized JSON array of weekday numbers, e.g. [1,2,3,4,5]
        t.string  :work_start_time, limit: 5  # 'HH:MM'
        t.string  :work_end_time,   limit: 5  # 'HH:MM'
        t.text    :holidays        # serialized JSON array of ISO dates
        t.timestamps
      end
    end

    # One SLA policy per project (the inheritance anchor).
    unless table_exists?(:sla_policies)
      create_table :sla_policies do |t|
        t.integer :project_id, null: false
        t.boolean :enabled, null: false, default: false
        t.string  :coverage_hours, null: false, default: '24x7', limit: 20 # '24x7' | 'business_hours'
        t.bigint  :business_calendar_id                                     # -> sla_business_calendars (bigint PK)
        t.string  :first_response_rule, null: false, default: 'either', limit: 20 # first_comment|first_status_change|either
        t.integer :at_risk_threshold, null: false, default: 80             # percent of target elapsed
        t.boolean :pause_enabled, null: false, default: true               # master switch for pause handling
        t.timestamps
      end
      add_index :sla_policies, :project_id, unique: true
      add_index :sla_policies, :enabled
      add_index :sla_policies, :business_calendar_id
      add_foreign_key :sla_policies, :projects, column: :project_id, on_delete: :cascade
    end

    # Per tracker x priority targets. Nullable target = that milestone is skipped.
    unless table_exists?(:sla_definitions)
      create_table :sla_definitions do |t|
        t.bigint  :sla_policy_id, null: false  # -> sla_policies (bigint PK)
        t.integer :tracker_id, null: false
        t.integer :priority_id, null: false
        t.integer :response_seconds    # nullable = skipped
        t.integer :workaround_seconds  # nullable = skipped
        t.integer :resolution_seconds  # nullable = skipped
        t.timestamps
      end
      add_index :sla_definitions, :sla_policy_id
      add_index :sla_definitions, [:sla_policy_id, :tracker_id, :priority_id],
                unique: true, name: 'idx_sla_definitions_policy_tracker_priority'
      add_foreign_key :sla_definitions, :sla_policies, column: :sla_policy_id, on_delete: :cascade
    end

    # Status milestones per policy. One row per (policy, role, status_id); role is a plugin enum,
    # status_id is the Redmine reference. Chip multi-select => many rows per role.
    unless table_exists?(:sla_status_mappings)
      create_table :sla_status_mappings do |t|
        t.bigint  :sla_policy_id, null: false  # -> sla_policies (bigint PK)
        t.string  :role, null: false, limit: 20 # created | work_started | resolved | pause
        t.integer :status_id, null: false
        t.timestamps
      end
      add_index :sla_status_mappings, :sla_policy_id
      add_index :sla_status_mappings, [:sla_policy_id, :role]
      add_index :sla_status_mappings, [:sla_policy_id, :role, :status_id],
                unique: true, name: 'idx_sla_status_mappings_unique'
      add_foreign_key :sla_status_mappings, :sla_policies, column: :sla_policy_id, on_delete: :cascade
    end

    # Per-issue computed cache (never computed on page load). One row per issue.
    unless table_exists?(:sla_results)
      create_table :sla_results do |t|
        t.integer  :issue_id, null: false
        t.integer  :project_id, null: false
        t.string   :primary_state, null: false, limit: 20 # met | breached | no_sla
        t.string   :no_sla_reason, limit: 20              # not_configured | not_tracked (when no_sla)
        t.boolean  :at_risk, null: false, default: false  # flag on a met ticket, not a state
        t.datetime :breach_at                             # projected breach time (open tickets)
        t.integer  :response_seconds
        t.integer  :workaround_seconds
        t.integer  :resolution_seconds
        t.integer  :deviation_seconds                     # breaches only
        t.datetime :calculated_at
        t.timestamps
      end
      # Indexes required by the plan: issue_id, project_id, primary_state, at_risk, breach_at.
      add_index :sla_results, :issue_id, unique: true
      add_index :sla_results, :project_id
      add_index :sla_results, :primary_state
      add_index :sla_results, :at_risk
      add_index :sla_results, :breach_at
    end

    # Admin-managed dropdown lookup for Response/Workaround/Resolution durations.
    unless table_exists?(:sla_target_options)
      create_table :sla_target_options do |t|
        t.string  :target_type, null: false, limit: 20 # response | workaround | resolution
        t.string  :code, null: false, limit: 50
        t.string  :label, null: false, limit: 100
        t.integer :seconds, null: false
        t.integer :position, null: false, default: 1
        t.timestamps
      end
      add_index :sla_target_options, :target_type
      add_index :sla_target_options, [:target_type, :code], unique: true
    end

    # Per-project notification configuration.
    unless table_exists?(:sla_notification_settings)
      create_table :sla_notification_settings do |t|
        t.integer :project_id, null: false
        t.text    :google_chat_webhook
        t.boolean :at_risk_email_enabled, null: false, default: false
        t.text    :at_risk_email_recipients                     # serialized JSON array of addresses
        t.string  :at_risk_email_frequency, limit: 20, default: 'realtime' # realtime | digest
        t.integer :at_risk_digest_interval_minutes, default: 60
        t.boolean :stale_email_enabled, null: false, default: false
        t.text    :stale_email_recipients                       # serialized JSON array of addresses
        t.string  :stale_email_frequency, limit: 20, default: 'weekly'
        t.timestamps
      end
      add_index :sla_notification_settings, :project_id, unique: true
      add_foreign_key :sla_notification_settings, :projects, column: :project_id, on_delete: :cascade
    end

    # Dedup + digest batching ledger for sent notifications.
    unless table_exists?(:sla_notification_logs)
      create_table :sla_notification_logs do |t|
        t.integer  :issue_id, null: false
        t.string   :notification_type, null: false, limit: 30 # at_risk | stale | google_chat_created
        t.string   :target, limit: 20                         # response|workaround|resolution (at_risk); nil otherwise
        t.datetime :sent_at
        t.timestamps
      end
      add_index :sla_notification_logs, :issue_id
      add_index :sla_notification_logs, [:issue_id, :notification_type, :target],
                name: 'idx_sla_notification_logs_dedup'
    end
  end

  def down
    drop_table :sla_notification_logs, if_exists: true
    drop_table :sla_notification_settings, if_exists: true
    drop_table :sla_target_options, if_exists: true
    drop_table :sla_results, if_exists: true
    drop_table :sla_status_mappings, if_exists: true
    drop_table :sla_definitions, if_exists: true
    drop_table :sla_policies, if_exists: true
    drop_table :sla_business_calendars, if_exists: true
  end
end
