# frozen_string_literal: true

require_relative '../../test_helper'

class Sla::GoogleChatMessageTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :issues, :issue_statuses, :trackers,
           :enumerations, :issue_categories, :versions, :roles, :members, :member_roles

  setup do
    @issue = Issue.find(1)
    @original_host = Setting.host_name
    @original_protocol = Setting.protocol
    Setting.host_name = 'redmine.example.com'
    Setting.protocol = 'https'
  end

  teardown do
    Setting.host_name = @original_host
    Setting.protocol = @original_protocol
  end

  def message_for(issue = @issue)
    ::I18n.with_locale(:en) { Sla::GoogleChatMessage.new(issue) }
  end

  test 'payload is one compact text message in the requested order' do
    payload = message_for.payload
    expected = [
      "🚨 New *#{@issue.tracker.name}* in *#{@issue.project.name}*",
      '',
      "*#{@issue.subject}* <https://redmine.example.com/issues/#{@issue.id}|##{@issue.id} ↗>",
      '',
      "Assignee: #{@issue.assigned_to&.name || Sla::GoogleChatMessage::BLANK}",
      "Status: #{@issue.status.name}",
      "Priority: #{@issue.priority.name}",
      "Created by: #{@issue.author.name}"
    ]

    assert_equal [:text], payload.keys
    assert_equal expected, payload[:text].lines(chomp: true)
  end

  test 'the tracker appears in the existing text body without a separate card' do
    tracker = Tracker.find(2)
    @issue.tracker = tracker
    payload = message_for.payload

    assert_equal [:text], payload.keys
    assert payload[:text].start_with?("🚨 New *#{tracker.name}* in *#{@issue.project.name}*")
  end

  test 'a missing tracker uses a generic issue label in the body' do
    @issue.stubs(:tracker).returns(nil)

    payload = message_for.payload
    assert payload[:text].start_with?("🚨 New *Issue* in *#{@issue.project.name}*")
  end

  test 'issue id and external-link icon are the custom hyperlink label' do
    assert_includes message_for.text,
                    "<https://redmine.example.com/issues/#{@issue.id}|##{@issue.id} ↗>"
  end

  test 'missing values render a dash while the issue link remains available' do
    @issue.subject = nil
    @issue.author = nil
    @issue.assigned_to = nil
    @issue.status = nil
    @issue.priority = nil
    @issue.stubs(:project).returns(nil)

    lines = message_for.text.lines(chomp: true)
    assert_equal "🚨 New *#{@issue.tracker.name}* in *—*", lines[0]
    assert_equal '', lines[1]
    assert_equal "*—* <https://redmine.example.com/issues/#{@issue.id}|##{@issue.id} ↗>", lines[2]
    assert_equal '', lines[3]
    assert_equal ['Assignee: —', 'Status: —', 'Priority: —', 'Created by: —'], lines.drop(4)
  end

  test 'user-controlled text cannot inject chat formatting links or extra lines' do
    @issue.subject = "*urgent* <https://bad.example|click>\nnext line"
    @issue.project.name = '`Project`'

    text = message_for.text
    assert_equal 8, text.lines.size
    assert_includes text, "🚨 New *#{@issue.tracker.name}* in *Project*"
    assert_includes text, '*urgent https://bad.exampleclick next line*'
    refute_includes text, 'https://bad.example|click'
  end
end
