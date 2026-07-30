# frozen_string_literal: true

module Sla
  # Step 7.1 — builds the Google Chat payload for a newly created issue.
  #
  # Deliberately pure: it takes an Issue and returns a Hash, with no HTTP, no DB writes and no
  # dependency on User.current (it runs inside a job, where there is no current user or request).
  # That keeps the whole message format unit-testable without any network or job infrastructure —
  # the same reasoning behind the injectable notifiers in `Sla::Sweep`.
  #
  # The field table is wrapped in a ``` fence because Google Chat renders normal message text in a
  # proportional font, where column padding would collapse; inside the fence it is monospaced and
  # the labels line up as designed.
  class GoogleChatMessage
    # Rendered in place of any unset field. Every row is ALWAYS emitted — a missing due date shows
    # a dash rather than silently disappearing, so the message has the same shape every time and a
    # reader can tell "not set" from "not included".
    BLANK = '—'

    FENCE = '```'

    # The message's fields, in render order. One ordered list is the single source of truth for
    # both the labels and the values, so adding, removing or reordering a row is a one-line change
    # here and nowhere else. Each entry is [i18n key, extractor]; extractors return nil freely and
    # `format_value` turns that into BLANK.
    #
    # Nothing domain-specific is hard-coded (Global Rule 1): tracker, status, priority, category
    # and version are all read off the issue's own associations, whatever the instance has
    # configured them to be.
    FIELDS = [
      ['field_sla_chat_reference',  ->(issue) { "##{issue.id}" }],
      ['field_sla_chat_title',      ->(issue) { issue.subject }],
      ['field_sla_chat_project',    ->(issue) { issue.project&.name }],
      ['field_sla_chat_type',       ->(issue) { issue.tracker&.name }],
      ['field_sla_chat_status',     ->(issue) { issue.status&.name }],
      ['field_sla_chat_priority',   ->(issue) { issue.priority&.name }],
      ['field_sla_chat_category',   ->(issue) { issue.category&.name }],
      ['field_sla_chat_version',    ->(issue) { issue.fixed_version&.name }],
      ['field_sla_chat_author',     ->(issue) { issue.author&.name }],
      ['field_sla_chat_assignee',   ->(issue) { issue.assigned_to&.name }],
      ['field_sla_chat_start_date', ->(issue) { issue.start_date }],
      ['field_sla_chat_due_date',   ->(issue) { issue.due_date }]
    ].freeze

    def initialize(issue)
      @issue = issue
    end

    # The Google Chat incoming-webhook body. `text` is the simplest payload Chat accepts and the
    # one that survives round-tripping through tests as a readable string.
    def payload
      { text: text }
    end

    def text
      [
        ::I18n.t('label_sla_chat_header', project: sanitize(@issue.project&.name)),
        '',
        ::I18n.t('text_sla_chat_intro'),
        '',
        FENCE,
        field_lines,
        FENCE,
        ::I18n.t('text_sla_chat_outro'),
        "🔗 #{issue_url}"
      ].join("\n")
    end

    private

    # Labels are padded to the widest RESOLVED label rather than to a hardcoded width, so the
    # columns stay aligned if a label is re-worded or translated into a longer language.
    def field_lines
      rows = FIELDS.map { |key, extractor| [::I18n.t(key), format_value(extractor.call(@issue))] }
      # +2 = room for the colon plus at least one space after the longest label.
      width = rows.map { |label, _| label.length }.max + 2
      rows.map { |label, value| "#{label}:".ljust(width) + value }.join("\n")
    end

    def format_value(value)
      return BLANK if value.blank?
      return ::I18n.l(value, format: :long) if value.is_a?(Date) || value.is_a?(Time)

      sanitize(value)
    end

    # Field values are user-supplied text sitting inside a ``` fence: a subject containing
    # backticks could otherwise close the fence early and wreck the rest of the message. Newlines
    # are flattened for the same reason — one field, one line.
    def sanitize(value)
      value.to_s.delete('`').gsub(/\s*\R\s*/, ' ').strip
    end

    # Reuses core's own host/port/path-prefix parsing (Mailer.default_url_options) instead of
    # re-deriving a URL from Setting.host_name — a job has no request to infer the host from, and
    # that method is already what every Redmine notification email uses.
    def issue_url
      Rails.application.routes.url_helpers.issue_url(@issue, Mailer.default_url_options)
    end
  end
end
