# frozen_string_literal: true

# Per-target-project schedule state for stale-ticket digests. The effective configuration may
# belong to the project, an ancestor, or the global record, but each target project must retain an
# independent window so one sibling cannot claim another sibling's digest.
class SlaNotificationDigestState < ActiveRecord::Base
  self.table_name = 'sla_notification_digest_states'

  belongs_to :project
  validates :project_id, presence: true, uniqueness: true

  class << self
    def claim_stale_window!(project_id, interval, now: Time.current)
      claim_window!(project_id, :last_stale_digest_at, interval, now: now)
    end

    def claim_at_risk_window!(project_id, interval, now: Time.current)
      claim_window!(project_id, :last_at_risk_digest_at, interval, now: now)
    end

    private

    def find_or_create_state!(project_id)
      find_or_create_by!(project_id: project_id)
    rescue ActiveRecord::RecordNotUnique
      retry
    end


    def claim_window!(project_id, column, interval, now:)
      state = find_or_create_state!(project_id)
      cutoff = now - interval
      claimed = where(id: state.id)
                .where("#{column} IS NULL OR #{column} <= ?", cutoff)
                .update_all(column => now, updated_at: now)
      claimed == 1 ? state.tap { |record| record.public_send("#{column}=", now) } : nil
    end
  end
end
