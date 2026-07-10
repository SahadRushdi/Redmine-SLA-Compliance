# frozen_string_literal: true

module Sla
  # Phase 2 · Step 2.5 — First-response detection (configurable per policy).
  #
  # Given a reconstructed timeline (Sla::TimelineBuilder::Timeline) and the policy's
  # `first_response_rule`, returns the timestamp of the first response, or nil if there is none
  # yet. The three rules mirror SlaPolicy::FIRST_RESPONSE_RULES:
  #
  #   * 'first_comment'        -> the first PUBLIC comment (private/internal notes never count)
  #   * 'first_status_change'  -> the first status transition
  #   * 'either'               -> whichever of the above happens first
  #
  # Private notes are excluded from the 'first_comment' and 'either' rules — an internal note is
  # not a customer-facing response.
  #
  # `since:` is the moment the response clock starts (default: the timeline's creation event).
  # Only responses strictly after that instant count, so a reopened ticket can be re-measured by
  # passing the reopen time (Step 2.6) without the reopen transition itself counting as a
  # response. Pure and side-effect free: reads only the timeline; no DB, no policy row.
  class FirstResponseDetector
    def initialize(timeline, rule:)
      @timeline = timeline
      @rule     = rule.to_s
    end

    def detect(since: :creation)
      lower_bound = since == :creation ? @timeline.created_event&.at : since

      candidates = response_events
      candidates = candidates.select { |event| event.at > lower_bound } if lower_bound
      candidates.min_by(&:at)&.at
    end

    private

    def response_events
      case @rule
      when 'first_comment'       then public_comments
      when 'first_status_change' then @timeline.status_changes
      when 'either'              then public_comments + @timeline.status_changes
      else
        raise ArgumentError, "unknown first_response_rule: #{@rule.inspect}"
      end
    end

    def public_comments
      @timeline.comments.reject(&:private_note)
    end
  end
end
