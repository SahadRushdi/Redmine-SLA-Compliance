# frozen_string_literal: true

module Sla
  # Builds the compact Google Chat text payload for a newly-created SLA issue. Delivery, tracker
  # eligibility and deduplication remain in SlaGoogleChatNotificationJob; this object is pure
  # formatting so the outbound contract is independently testable.
  class GoogleChatMessage
    BLANK = '—'

    def initialize(issue)
      @issue = issue
    end

    def payload
      { text: text }
    end

    def text
      [
        ::I18n.t('text_sla_chat_new_issue', project: bold(format_value(@issue.project&.name))),
        "#{format_value(@issue.subject)} #{issue_link}",
        field_line('field_sla_chat_author', @issue.author&.name),
        field_line('field_sla_chat_assignee', @issue.assigned_to&.name),
        field_line('field_sla_chat_status', @issue.status&.name),
        field_line('field_sla_chat_priority', @issue.priority&.name)
      ].join("\n")
    end

    private

    def field_line(key, value)
      "#{::I18n.t(key)}: #{format_value(value)}"
    end

    # Google Chat text messages use <url|label> for custom links. The link label includes the
    # external-link glyph requested by the UI; Chat itself controls the browser/tab behavior.
    def issue_link
      "<#{issue_url}|##{@issue.id} ↗>"
    end

    def bold(value)
      "*#{value}*"
    end

    def format_value(value)
      value.present? ? sanitize(value) : BLANK
    end

    # Flatten user-controlled values to one line and neutralize Chat text markup/link delimiters.
    # Removing the delimiters is intentional: these fields are content, never formatting input.
    def sanitize(value)
      value.to_s.gsub(/[\n\r]+/, ' ').gsub(/[*_~`<>|]/, '').squish
    end

    def issue_url
      Rails.application.routes.url_helpers.issue_url(@issue, Mailer.default_url_options)
    end
  end
end
