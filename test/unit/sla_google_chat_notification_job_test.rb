# frozen_string_literal: true

require_relative '../test_helper'

# Step 7.1 — the notification job's gate chain and failure behaviour.
# The HTTP client is always injected, so nothing here touches the network.
class SlaGoogleChatNotificationJobTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :issues, :issue_statuses, :trackers,
           :projects_trackers, :enumerations, :roles, :members, :member_roles, :enabled_modules

  SLA_TRACKER   = 1
  OTHER_TRACKER = 2
  PRIORITY      = 6 # High
  WEBHOOK       = 'https://chat.googleapis.com/v1/spaces/AAA/messages?key=k'

  # Records what would have been posted, in place of Sla::GoogleChatClient. Mirrors the
  # hand-rolled FakeNotifier collaborators in sweep_test.rb rather than pulling in an HTTP stub.
  class FakeClient
    attr_reader :calls

    def initialize(error: nil)
      @calls = []
      @error = error
    end

    def post(url, payload)
      @calls << [url, payload]
      raise @error if @error
    end
  end

  setup do
    User.current = User.find(2)
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    @original_settings = Setting.plugin_redmine_sla_compliance
    Setting.plugin_redmine_sla_compliance = {}
    configure_sla(@project)

    # after_commit DOES fire in this transactional test env, and the test queue adapter is
    # :inline — so without this every `make_issue` below would run the job for real, with the real
    # HTTP client, against the webhook URLs these tests configure. Each test drives `perform`
    # explicitly with its own fake client instead.
    SlaGoogleChatNotificationJob.stubs(:perform_later)
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = @original_settings
    User.current = nil
  end

  # A policy covering SLA_TRACKER only — OTHER_TRACKER is deliberately left unconfigured so the
  # "non-SLA trackers do not post" case is exercised against a real policy, not against an
  # absent one.
  def configure_sla(project)
    policy = SlaPolicy.create!(project_id: project.id, enabled: true, coverage_hours: '24x7',
                               first_response_rule: 'either', at_risk_threshold: 80,
                               pause_enabled: true)
    SlaStatusMapping.create!(sla_policy: policy, role: 'created', status_id: 1)
    SlaDefinition.create!(sla_policy: policy, tracker_id: SLA_TRACKER, priority_id: PRIORITY,
                          response_seconds: 3600)
    policy
  end

  def set_webhook(url, project: @project)
    SlaNotificationSetting.create!(project_id: project.id, google_chat_webhook: url)
  end

  def make_issue(tracker_id: SLA_TRACKER, project: @project)
    issue = Issue.new(project_id: project.id, tracker_id: tracker_id, author_id: 2,
                      priority_id: PRIORITY, status_id: 1, subject: 'chat notification test')
    issue.save!(validate: false)
    issue
  end

  def run_job(issue_id, client)
    SlaGoogleChatNotificationJob.new.perform(issue_id, client: client)
    client
  end

  test "posts for an issue on an SLA-configured tracker" do
    set_webhook(WEBHOOK)
    issue = make_issue

    client = run_job(issue.id, FakeClient.new)

    assert_equal 1, client.calls.size
    url, payload = client.calls.first
    assert_equal WEBHOOK, url
    assert_includes payload[:text], "##{issue.id}"
  end

  test "does not post for an issue on a tracker with no SLA definition" do
    set_webhook(WEBHOOK)
    issue = make_issue(tracker_id: OTHER_TRACKER)

    assert_empty run_job(issue.id, FakeClient.new).calls
  end

  test "does not post when the SLA module is disabled on the project" do
    set_webhook(WEBHOOK)
    issue = make_issue
    @project.disable_module!(:sla_compliance)

    assert_empty run_job(issue.id, FakeClient.new).calls
  end

  test "does not post when no webhook is configured anywhere" do
    issue = make_issue

    assert_empty run_job(issue.id, FakeClient.new).calls
  end

  test "does not post when the issue no longer exists" do
    set_webhook(WEBHOOK)

    assert_empty run_job(0, FakeClient.new).calls
  end

  test "posts to the project's own webhook" do
    # There is no instance-wide fallback any more (removed 2026-08-05 with its admin field), so the
    # project's own value is the only source there is.
    set_webhook(WEBHOOK)
    issue = make_issue

    assert_equal WEBHOOK, run_job(issue.id, FakeClient.new).calls.first.first
  end

  test "running the job twice posts exactly once" do
    set_webhook(WEBHOOK)
    issue = make_issue
    client = FakeClient.new

    2.times { SlaGoogleChatNotificationJob.new.perform(issue.id, client: client) }

    assert_equal 1, client.calls.size
    assert_equal 1, SlaNotificationLog.where(issue_id: issue.id,
                                             notification_type: 'google_chat_created').count
  end

  test "a delivery failure is logged and never raised" do
    set_webhook(WEBHOOK)
    issue = make_issue
    client = FakeClient.new(error: Sla::GoogleChatClient::DeliveryError.new('HTTP 404'))

    assert_nothing_raised { SlaGoogleChatNotificationJob.new.perform(issue.id, client: client) }
    assert_equal 1, client.calls.size, 'the post must have been attempted'
  end

  test "sent_at is stamped on success and left nil on failure" do
    set_webhook(WEBHOOK)

    ok = make_issue
    run_job(ok.id, FakeClient.new)
    assert_not_nil log_for(ok).sent_at

    failed = make_issue
    run_job(failed.id, FakeClient.new(error: StandardError.new('boom')))
    assert_nil log_for(failed).sent_at
  end

  def log_for(issue)
    SlaNotificationLog.find_by(issue_id: issue.id, notification_type: 'google_chat_created')
  end
end
