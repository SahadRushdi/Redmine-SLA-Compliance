# frozen_string_literal: true

require_relative '../test_helper'

class SlaEmailDeliveryJobTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :enumerations

  setup do
    ActionMailer::Base.deliveries.clear
    @project = Project.find(1)
    @user = @project.users.joins(:email_address).first
    @setting = SlaNotificationSetting.create!(project_id: @project.id,
                                               at_risk_email_enabled: true)
    @setting.replace_recipient_user_ids!(:at_risk, [@user.id])
    @issue = Issue.find(1)
    @log = SlaNotificationLog.create!(issue_id: @issue.id, notification_type: 'at_risk',
                                      target: 'response', cycle_key: 'phase8',
                                      delivery_state: 'queued')
  end

  test 'delivers a personalized multipart email and stamps the log once' do
    SlaEmailDeliveryJob.new.perform('at_risk_realtime', @project.id, [@log.id], @setting.id)

    assert_equal 1, ActionMailer::Base.deliveries.size
    message = ActionMailer::Base.deliveries.first
    assert_equal [@user.mail], message.to
    assert message.multipart?
    assert_includes message.html_part.body.decoded, ERB::Util.html_escape(@issue.subject)
    assert_equal 'sent', @log.reload.delivery_state
    assert_not_nil @log.sent_at
  end

  test 'a delivery exception is logged as failed and never raised' do
    SlaMailer.stubs(:at_risk_alert).raises(StandardError, 'smtp unavailable')

    assert_nothing_raised do
      SlaEmailDeliveryJob.new.perform('at_risk_realtime', @project.id, [@log.id], @setting.id)
    end
    assert_equal 'failed', @log.reload.delivery_state
    assert_match(/smtp unavailable/, @log.failure_message)
  end

  test 'a configured outsider is removed by delivery-time project authorization' do
    outsider = User.active.joins(:email_address).where.not(id: @project.users.select(:id)).first
    @setting.replace_recipient_user_ids!(:at_risk, [outsider.id])

    SlaEmailDeliveryJob.new.perform('at_risk_realtime', @project.id, [@log.id], @setting.id)

    assert_empty ActionMailer::Base.deliveries
    assert_equal 'failed', @log.reload.delivery_state
  end

  test 'stale digest renders the required ticket fields' do
    @setting.replace_recipient_user_ids!(:stale, [@user.id])
    @log.update_columns(notification_type: 'stale', target: '')

    SlaEmailDeliveryJob.new.perform('stale_digest', @project.id, [@log.id], @setting.id)

    body = ActionMailer::Base.deliveries.first.html_part.body.decoded
    [@issue.subject, @issue.status.to_s, @issue.project.to_s].each { |value| assert_includes body, value }
    assert_includes body, I18n.t(:field_created_on)
    assert_includes body, I18n.t(:field_updated_on)
    assert_includes body, I18n.t(:field_assigned_to)
    assert_equal 'sent', @log.reload.delivery_state
  end
end
