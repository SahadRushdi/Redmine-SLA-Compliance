# frozen_string_literal: true

module Sla
  # Phase 2 · Step 2.1 — Timeline reconstruction from journals.
  #
  # Produces an ordered timeline of an issue's status transitions and comment events, read
  # from Redmine's journal history (`journals` / `journal_details`) — the source of truth —
  # rather than the issue's current state.
  #
  # This service is deliberately POLICY-AGNOSTIC and side-effect free:
  #   * it only READS `issue.journals`; it never writes to the database and never touches
  #     `sla_results`;
  #   * it hard-codes no statuses (Global Rule 1) and stores only integer `status_id`s,
  #     never label strings (Global Rule 2);
  #   * it does not decide which transition is a "reopen" / clock-restart — that is Step 2.6's
  #     job, using this raw timeline plus the policy's `created`-role status mapping. Here we
  #     only reconstruct every transition faithfully and in order (incl. reopened issues).
  #
  # Private notes are captured and FLAGGED (`private_note: true`) but not filtered — Step 2.5
  # (first-response detection) performs the exclusion; capturing the flag now enables it.
  class TimelineBuilder
    # A single reconstructed event. `type` is one of :created | :status_change | :comment.
    #   :created       -> to_status_id = the issue's initial status; at = issue.created_on
    #   :status_change -> from_status_id / to_status_id; at = journal.created_on
    #   :comment       -> private_note flag; at = journal.created_on
    Event = Struct.new(
      :type, :at, :from_status_id, :to_status_id, :journal_id, :user_id, :private_note,
      keyword_init: true
    )

    # Deterministic ordering rank for events sharing a timestamp (e.g. one journal carrying
    # both a status change and a note): creation first, then the status change, then the note.
    TYPE_RANK = { created: 0, status_change: 1, comment: 2 }.freeze

    def initialize(issue)
      @issue = issue
    end

    def build
      status_changes = []
      comments = []

      journals.each do |journal|
        journal.details.each do |detail|
          next unless status_detail?(detail)

          status_changes << Event.new(
            type: :status_change,
            at: journal.created_on,
            from_status_id: to_status_id(detail.old_value),
            to_status_id: to_status_id(detail.value),
            journal_id: journal.id,
            user_id: journal.user_id
          )
        end

        next if journal.notes.blank?

        comments << Event.new(
          type: :comment,
          at: journal.created_on,
          journal_id: journal.id,
          user_id: journal.user_id,
          private_note: journal.private_notes?
        )
      end

      created = Event.new(
        type: :created,
        at: @issue.created_on,
        to_status_id: initial_status_id(status_changes)
      )

      events = sort_events([created] + status_changes + comments)
      Timeline.new(events)
    end

    private

    # Fresh, ordered query (re-queries even if the association is cached) with `:details`
    # eager-loaded to avoid N+1, per the plugin's query conventions.
    def journals
      @issue.journals.includes(:details).reorder(:created_on, :id)
    end

    def status_detail?(detail)
      detail.property == 'attr' && detail.prop_key == 'status_id'
    end

    # Journal detail values are stored as strings; a blank means "no value" (nil).
    def to_status_id(raw)
      raw.blank? ? nil : raw.to_i
    end

    # Initial status = the `old_value` of the first status change. Real Redmine status-change
    # journals always carry `old_value`, so the fallback to the issue's *current* status only
    # applies when the issue never changed status at all (no status journals).
    def initial_status_id(status_changes)
      first = status_changes.min_by { |e| [e.at, e.journal_id.to_i] }
      (first && first.from_status_id) || @issue.status_id
    end

    def sort_events(events)
      events.sort_by { |e| [e.at, e.journal_id.to_i, TYPE_RANK.fetch(e.type)] }
    end

    # Lean, immutable value object wrapping the ordered event list plus the derived views that
    # later engine steps consume.
    class Timeline
      attr_reader :events

      def initialize(events)
        @events = events.freeze
      end

      def created_event
        @events.find { |e| e.type == :created }
      end

      def status_changes
        @events.select { |e| e.type == :status_change }
      end

      def comments
        @events.select { |e| e.type == :comment }
      end

      def initial_status_id
        created_event&.to_status_id
      end

      # The last thing that happened to this issue on the record — the newest journal entry, or
      # creation for an issue that has none. Used by ResultClassifier#closed_at as the best
      # available stand-in for a resolution instant when the issue sits in a resolved status with
      # no transition into it recorded (imported, or resolved before that status was mapped).
      def last_event_at
        @events.last&.at
      end

      # Per-status spans reconstructed from the transition sequence:
      #   [{ status_id:, started_at:, ended_at: }, ...]
      # The final span's `ended_at` is nil (the issue is still in that status). Built purely
      # from the ordered `to_status_id` sequence; `from_status_id` is informational only.
      def status_intervals
        intervals = []
        current = { status_id: initial_status_id, started_at: created_event&.at, ended_at: nil }

        status_changes.each do |change|
          current[:ended_at] = change.at
          intervals << current
          current = { status_id: change.to_status_id, started_at: change.at, ended_at: nil }
        end

        intervals << current
        intervals
      end
    end
  end
end
