# frozen_string_literal: true

require_relative '../../test_helper'

# Step 7.1 — the Google Chat message body. Pure formatting: no HTTP, no job, no DB writes.
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

  def text_for(issue)
    ::I18n.with_locale(:en) { Sla::GoogleChatMessage.new(issue).text }
  end

  # The label of a field row, as it appears in the rendered table.
  def row_value(text, label)
    line = text.lines.find { |l| l.start_with?("#{label}:") }
    assert_not_nil line, "expected a #{label} row in:\n#{text}"
    line.split(':', 2).last.strip
  end

  test "payload is a text message" do
    payload = ::I18n.with_locale(:en) { Sla::GoogleChatMessage.new(@issue).payload }
    assert_equal [:text], payload.keys
    assert_kind_of String, payload[:text]
  end

  test "every configured field is rendered, in order" do
    text = text_for(@issue)
    labels = Sla::GoogleChatMessage::FIELDS.map { |key, _| ::I18n.with_locale(:en) { ::I18n.t(key) } }

    positions = labels.map do |label|
      index = text.index("#{label}:")
      assert_not_nil index, "expected a #{label} row in:\n#{text}"
      index
    end
    assert_equal positions.sort, positions, 'rows must render in FIELDS order'
  end

  test "the header carries the project name and the body carries the reference" do
    text = text_for(@issue)
    assert_includes text, @issue.project.name
    assert_equal "##{@issue.id}", row_value(text, 'Reference')
    assert_equal @issue.subject, row_value(text, 'Title')
    assert_equal @issue.tracker.name, row_value(text, 'Type')
    assert_equal @issue.status.name, row_value(text, 'Status')
    assert_equal @issue.priority.name, row_value(text, 'Priority')
    assert_equal @issue.author.name, row_value(text, 'Submitted By')
  end

  test "the field table sits inside a code fence so the columns stay aligned" do
    text = text_for(@issue)
    assert_equal 2, text.scan(Sla::GoogleChatMessage::FENCE).size, 'expected exactly one fenced block'

    fenced = text.split(Sla::GoogleChatMessage::FENCE)[1]
    value_columns = fenced.lines.reject { |l| l.strip.empty? }.map { |l| l.index(/\S/, l.index(':') + 1) }
    assert_equal 1, value_columns.uniq.size, "values must start at one column:\n#{fenced}"
  end

  test "unset fields render a dash and the row is still present" do
    @issue.assigned_to = nil
    @issue.category = nil
    @issue.fixed_version = nil
    @issue.start_date = nil
    @issue.due_date = nil

    text = text_for(@issue)
    ['Assigned To', 'Category', 'Target Version', 'Start Date', 'Due Date'].each do |label|
      assert_equal Sla::GoogleChatMessage::BLANK, row_value(text, label),
                   "#{label} must render a dash when unset"
    end
  end

  test "dates render in long form" do
    @issue.due_date = Date.new(2026, 7, 15)
    assert_equal 'July 15, 2026', row_value(text_for(@issue), 'Due Date')
  end

  test "a subject containing backticks cannot break out of the code fence" do
    @issue.subject = "broken ``` fence\nattempt"

    text = text_for(@issue)
    assert_equal 2, text.scan(Sla::GoogleChatMessage::FENCE).size
    assert_equal 'broken  fence attempt', row_value(text, 'Title')
  end

  test "the link points at the issue on the configured host" do
    text = text_for(@issue)
    assert_includes text, "https://redmine.example.com/issues/#{@issue.id}"
  end
end
