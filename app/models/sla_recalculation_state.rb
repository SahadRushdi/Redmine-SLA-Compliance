# frozen_string_literal: true

require 'securerandom'

# Durable, project-scoped progress for historical SLA recalculation. A single row is reused for
# successive runs, so this is operational state rather than an unbounded execution history.
class SlaRecalculationState < ActiveRecord::Base
  self.table_name = 'sla_recalculation_states'

  ACTIVE_STATUSES = %w[queued running].freeze
  STATUSES = (ACTIVE_STATUSES + %w[completed failed]).freeze
  STALE_AFTER = 1.hour

  belongs_to :project

  validates :project_id, uniqueness: true
  validates :run_token, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :total_count, :processed_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def self.request!(project, now: Time.current)
    state = find_by(project_id: project.id)
    unless state
      begin
        state = create!({ project_id: project.id }.merge(new_run_attributes(now)))
        return [state, true]
      rescue ActiveRecord::RecordNotUnique
        state = find_by!(project_id: project.id)
      end
    end
    enqueue = false

    state.with_lock do
      if state.active? && !state.stale?(now)
        # A queued job has not read configuration yet, so another request is already covered by
        # that pass. A running job may have processed tickets against the old policy; coalesce one
        # follow-up pass to make the final cache internally consistent.
        state.update!(rerun_requested: true) if state.status == 'running' && !state.rerun_requested?
      else
        state.assign_attributes(new_run_attributes(now))
        state.save!
        enqueue = true
      end
    end

    [state, enqueue]
  end

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def stale?(now = Time.current)
    active? && updated_at.present? && updated_at < now - STALE_AFTER
  end

  def progress_percentage
    return 100 if status == 'completed'
    return 0 if total_count.to_i.zero?

    [(processed_count.to_f * 100 / total_count).floor, 100].min
  end

  def start!(token, now: Time.current)
    with_lock do
      return false unless run_token == token && %w[queued failed].include?(status)

      update!(status: 'running', total_count: 0, processed_count: 0, started_at: now,
              finished_at: nil, error_message: nil)
    end
    true
  end

  def record_progress!(token, processed:, total:)
    return false unless run_token == token && status == 'running'

    processed = [processed.to_i, 0].max
    total = [total.to_i, 0].max
    next_percentage = total.zero? ? 0 : [(processed.to_f * 100 / total).floor, 100].min
    current_percentage = progress_percentage
    return false if total_count == total && next_percentage == current_percentage

    changed = self.class.where(id: id, run_token: token, status: 'running').update_all(
      processed_count: [processed, total].min, total_count: total, updated_at: Time.current
    )
    reload if changed == 1
    changed == 1
  end

  # Atomically decides whether another pass is required. A request racing with this method either
  # sets rerun_requested before the decision, or sees completed and enqueues a new token afterward.
  def finish_pass!(token, processed:, now: Time.current)
    outcome = nil
    with_lock do
      return :obsolete unless run_token == token && status == 'running'

      if rerun_requested?
        update!(rerun_requested: false, total_count: 0, processed_count: 0, updated_at: now)
        outcome = :rerun
      else
        update!(status: 'completed', processed_count: processed, total_count: processed,
                finished_at: now, error_message: nil)
        outcome = :completed
      end
    end
    outcome
  end

  def fail!(token, message:, now: Time.current)
    with_lock do
      return false unless run_token == token

      update!(status: 'failed', rerun_requested: false, finished_at: now,
              error_message: message.to_s.truncate(255))
    end
    true
  end

  class << self
    private

    def new_run_attributes(now)
      {
        run_token: SecureRandom.hex(16), status: 'queued', total_count: 0, processed_count: 0,
        rerun_requested: false, started_at: nil, finished_at: nil, error_message: nil,
        updated_at: now
      }
    end
  end
end
