# frozen_string_literal: true

# Project-scoped or singleton-admin notification configuration: Google Chat webhook, at-risk email
# (real-time or digest) and stale-ticket email. Recipient lists are stored as JSON arrays.
class SlaNotificationSetting < ActiveRecord::Base
  self.table_name = 'sla_notification_settings'

  GLOBAL_SCOPE_KEY = 'global'

  # Plugin-internal frequency enums.
  AT_RISK_FREQUENCIES = %w[realtime digest].freeze
  STALE_FREQUENCIES   = %w[daily weekly monthly].freeze

  # Everything a clone carries from one project's notification setup to another's — the same
  # "name the copied slice once" convention as SlaDefinition::COPY_ATTRIBUTES, so a new column
  # cannot be remembered in the form and forgotten in the copier.
  #
  # `last_stale_digest_at` is deliberately absent. It is retained only as legacy upgrade state;
  # active schedule claims live in SlaNotificationDigestState and are always per target project.
  COPY_ATTRIBUTES = %w[google_chat_webhook
                       at_risk_email_enabled at_risk_email_recipients at_risk_email_frequency
                       at_risk_digest_interval_minutes
                       stale_email_enabled stale_email_recipients stale_email_frequency
                       stale_threshold_days].freeze

  belongs_to :project, optional: true

  serialize :at_risk_email_recipients, JSON
  serialize :stale_email_recipients, JSON

  before_validation :assign_scope_key

  validates :project_id, presence: true, uniqueness: true, unless: :global?
  validates :project_id, absence: true, if: :global?
  validates :scope_key, presence: true, uniqueness: true
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

  def self.global
    find_by(scope_key: GLOBAL_SCOPE_KEY)
  end

  def self.global_for_form
    global || new(scope_key: GLOBAL_SCOPE_KEY)
  end

  # Compatibility facade for the Google Chat job. All precedence lives in the shared resolver so
  # every channel follows the same project → nearest parent → administration rule.
  def self.google_chat_webhook_for(project)
    return nil unless project

    Sla::NotificationSettingsResolver.new(project).resolve(:google_chat)
                                     .setting&.google_chat_webhook.presence
  end

  def global?
    scope_key == GLOBAL_SCOPE_KEY
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

  private

  def assign_scope_key
    self.scope_key = "project:#{project_id}" if project_id.present?
  end

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
