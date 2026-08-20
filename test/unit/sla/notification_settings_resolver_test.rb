# frozen_string_literal: true

require_relative '../../test_helper'

class Sla::NotificationSettingsResolverTest < ActiveSupport::TestCase
  fixtures :projects

  PARENT = 1
  CHILD = 3

  def create_setting(project_id: nil, global: false, **attributes)
    scope = global ? { scope_key: SlaNotificationSetting::GLOBAL_SCOPE_KEY } : { project_id: project_id }
    SlaNotificationSetting.create!(scope.merge(attributes))
  end

  test 'resolves every channel independently across project parent and admin sources' do
    create_setting(project_id: CHILD, google_chat_webhook: 'https://chat.example.test/child')
    parent = create_setting(project_id: PARENT, at_risk_email_enabled: true,
                            at_risk_email_recipients: ['parent@example.test'])
    admin = create_setting(global: true, stale_email_enabled: true,
                           stale_email_recipients: ['admin@example.test'])

    resolver = Sla::NotificationSettingsResolver.new(Project.find(CHILD))
    chat = resolver.resolve(:google_chat)
    risk = resolver.resolve(:at_risk_email)
    stale = resolver.resolve(:stale_email)

    assert_equal :project, chat.source
    assert_equal :parent, risk.source
    assert_equal parent, risk.setting
    assert_equal Project.find(PARENT), risk.source_project
    assert_equal :admin, stale.source
    assert_equal admin, stale.setting
  end

  test 'inactive project values fall through and nearest active parent wins' do
    create_setting(project_id: 6, at_risk_email_enabled: false)
    nearest = create_setting(project_id: 5, at_risk_email_enabled: true)
    create_setting(project_id: PARENT, at_risk_email_enabled: true)
    create_setting(global: true, at_risk_email_enabled: true)

    resolution = Sla::NotificationSettingsResolver.new(Project.find(6)).resolve(:at_risk_email)

    assert_equal :parent, resolution.source
    assert_equal nearest, resolution.setting
  end

  test 'returns an unconfigured resolution when no source is active' do
    create_setting(project_id: CHILD, stale_email_enabled: false)
    create_setting(global: true, stale_email_enabled: false)

    resolution = Sla::NotificationSettingsResolver.new(Project.find(CHILD)).resolve(:stale_email)

    refute resolution.configured?
    assert_nil resolution.source
  end
end
