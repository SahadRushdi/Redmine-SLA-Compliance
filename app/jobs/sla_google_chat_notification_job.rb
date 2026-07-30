# frozen_string_literal: true

# Step 7.1 — posts a Google Chat message when an issue is created on an SLA-configured tracker.
#
# Enqueued from IssuePatch's after_commit(on: :create) so it runs entirely off the request: the
# user's issue save is never delayed by a webhook round-trip, and a webhook that is down or slow
# cannot affect issue creation at all (Global Rule 4).
#
# The hook only performs the cheap module check before enqueuing; every other gate lives here, both
# because they are DB queries that would otherwise be paid on the save path, and because the job
# runs later — the policy, the webhook, or the issue itself may have changed in between, so each
# condition is re-checked at the moment of sending rather than trusted from enqueue time.
class SlaGoogleChatNotificationJob < ApplicationJob
  queue_as :default

  # @param issue_id [Integer]
  # @param client   [#post] injectable so tests never perform real HTTP
  def perform(issue_id, client: Sla::GoogleChatClient.new)
    issue = Issue.find_by(id: issue_id)
    return unless issue&.project&.module_enabled?(:sla_compliance)

    webhook = SlaNotificationSetting.google_chat_webhook_for(issue.project)
    return if webhook.blank?

    # "SLA-configured tracker" = the effective (possibly inherited) policy has at least one
    # definition for this tracker, whatever its priority. Asked of PolicyContext so this shares one
    # answer with the classifier instead of re-implementing the lookup — and so nothing here names
    # a tracker; it is all resolved from the project's own configuration by ID (Global Rules 1, 2).
    return unless Sla::PolicyContext.for_project(issue.project).tracker_configured?(issue.tracker_id)

    # Claim BEFORE sending: the claim is an atomic insert against a unique index, so a retried or
    # accidentally duplicated job can never produce a second message in the space. The cost is that
    # a failed POST is not retried automatically — a deliberate trade (a duplicate alert is worse
    # than a missed one here), and the un-stamped sent_at below leaves the failure visible.
    return unless SlaNotificationLog.claim!(issue_id: issue.id,
                                            notification_type: 'google_chat_created')

    deliver(issue, webhook, client)
  rescue StandardError => e
    # Never re-raised: a webhook failure is logged and dropped. Re-raising would put the job into
    # the adapter's retry path and, more importantly, is not something the user creating the issue
    # should ever be able to observe.
    Rails.logger.error(
      "[SLA] Google Chat notification failed for issue ##{issue_id}: #{e.class}: #{e.message}"
    )
  end

  private

  def deliver(issue, webhook, client)
    # A job has no User.current to inherit a locale from, so the message is built in the
    # instance's default language rather than whatever locale happened to be left on the thread.
    payload = I18n.with_locale(Setting.default_language) { Sla::GoogleChatMessage.new(issue).payload }
    client.post(webhook, payload)

    # Stamped only after a successful POST, so `sent_at IS NULL` on a claimed row is the audit
    # trail of an attempted-but-failed delivery.
    SlaNotificationLog.where(issue_id: issue.id, notification_type: 'google_chat_created')
                      .update_all(sent_at: Time.current)
  end
end
