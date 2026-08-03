# frozen_string_literal: true

# Per-project notification configuration: Google Chat webhook, at-risk email (real-time or
# digest) and stale-ticket email. Recipient lists are stored as JSON arrays of addresses.
class SlaNotificationSetting < ActiveRecord::Base
  self.table_name = 'sla_notification_settings'

  # Plugin-internal frequency enums.
  AT_RISK_FREQUENCIES = %w[realtime digest].freeze
  STALE_FREQUENCIES   = %w[daily weekly monthly].freeze

  # Everything a clone carries from one project's notification setup to another's — the same
  # "name the copied slice once" convention as SlaDefinition::COPY_ATTRIBUTES, so a new column
  # cannot be remembered in the form and forgotten in the copier.
  #
  # `last_stale_digest_at` is deliberately absent. It is the digest SCHEDULE's claim (see
  # .claim_stale_digest_window!), not configuration: copying it would hand the target project the
  # source's already-claimed window and swallow its first digest.
  COPY_ATTRIBUTES = %w[google_chat_webhook
                       at_risk_email_enabled at_risk_email_recipients at_risk_email_frequency
                       at_risk_digest_interval_minutes
                       stale_email_enabled stale_email_recipients stale_email_frequency
                       stale_threshold_days].freeze

  belongs_to :project

  serialize :at_risk_email_recipients, JSON
  serialize :stale_email_recipients, JSON

  validates :project_id, presence: true, uniqueness: true
  validates :at_risk_email_frequency, inclusion: { in: AT_RISK_FREQUENCIES }
  validates :stale_email_frequency, inclusion: { in: STALE_FREQUENCIES }
  validates :at_risk_digest_interval_minutes,
            numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :stale_threshold_days,
            numericality: { only_integer: true, greater_than: 0 }
  # Caught at save time so a mistyped webhook surfaces in the form, rather than silently becoming
  # a log line every time somebody creates an issue. https only — Google Chat webhooks are always
  # https, and posting issue details over plain http would be a downgrade nobody asked for.
  validates :google_chat_webhook, format: { with: %r{\Ahttps://\S+\z} }, allow_blank: true
  validate :recipients_are_valid_emails

  # Step 7.1 — which webhook does +project+ post to? The project's own value, else the
  # instance-wide default from Administration → Plugins (the plan's "per-project setting, with a
  # global fallback"). Note this deliberately does NOT walk up the project tree the way SLA
  # policies do: the form shows a single field with no indication that a value might be inherited
  # from a parent, so inheriting one silently would post to a space the project's admin never saw.
  def self.google_chat_webhook_for(project)
    return nil unless project

    own = find_by(project_id: project.id)&.google_chat_webhook
    own.presence || Sla::PluginSettings.default_google_chat_webhook
  end

  # --- Step 4.7: clone ------------------------------------------------------------------------
  # An UNSAVED setting for +project+ mirroring +source+ — the form-population vehicle for a clone
  # load, exactly as Sla::PolicyPrefill is for the policy itself. Unlike a policy there is nothing
  # to filter out: every attribute here is a plain value, not a reference that could be invalid in
  # another project. Returns the project's own setting untouched when there is no source.
  def self.prefill_for(project, source)
    setting = find_by(project_id: project.id) || new(project_id: project.id)
    setting.assign_attributes(source.attributes.slice(*COPY_ATTRIBUTES)) if source
    setting
  end

  # The save half of the same operation. Upserts, so cloning onto a project that already has
  # notification settings replaces them rather than erroring on the unique project_id index.
  def self.copy_to!(project, source)
    setting = find_or_initialize_by(project_id: project.id)
    setting.assign_attributes(source.attributes.slice(*COPY_ATTRIBUTES))
    setting.save!
    setting
  end

  FREQUENCY_INTERVALS = { 'daily' => 1.day, 'weekly' => 1.week, 'monthly' => 1.month }.freeze

  # How much wall-clock time must pass between stale-ticket digests, per the configured
  # frequency (defaults to weekly per the plan's Fixed Decisions if an unknown value sneaks in).
  def stale_digest_interval
    FREQUENCY_INTERVALS.fetch(stale_email_frequency, 1.week)
  end

  # Atomically claim +project_id+'s stale-digest window: this is the sweep's schedule gate,
  # mirroring `SlaNotificationLog.claim!`'s use of a real DB constraint instead of an app-level
  # check-then-act. The conditional `UPDATE ... WHERE` only affects a row (and returns 1) if no
  # other process has already claimed this window — safe under concurrent sweeps across multiple
  # app-server workers. Returns the setting (for its recipients/threshold) when this call won the
  # claim, or nil when digests are disabled or another process already claimed this period.
  def self.claim_stale_digest_window!(project_id, now: Time.current)
    setting = find_by(project_id: project_id)
    return nil unless setting&.stale_email_enabled?

    cutoff = now - setting.stale_digest_interval
    claimed_rows = where(id: setting.id)
                   .where('last_stale_digest_at IS NULL OR last_stale_digest_at <= ?', cutoff)
                   .update_all(last_stale_digest_at: now)
    claimed_rows == 1 ? setting : nil
  end

  private

  EMAIL_RE = URI::MailTo::EMAIL_REGEXP

  def recipients_are_valid_emails
    { at_risk_email_recipients: at_risk_email_recipients,
      stale_email_recipients: stale_email_recipients }.each do |attr, list|
      next if list.blank?
      unless list.is_a?(Array) && list.all? { |e| e.to_s.match?(EMAIL_RE) }
        errors.add(attr, :invalid)
      end
    end
  end
end
