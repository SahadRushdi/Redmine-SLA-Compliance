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
      state = find_or_create_state!(project_id)
      cutoff = now - interval
      claimed = where(id: state.id)
                .where('last_stale_digest_at IS NULL OR last_stale_digest_at <= ?', cutoff)
                .update_all(last_stale_digest_at: now, updated_at: now)
      claimed == 1 ? state.tap { |record| record.last_stale_digest_at = now } : nil
    end

    private

    def find_or_create_state!(project_id)
      find_or_create_by!(project_id: project_id)
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
