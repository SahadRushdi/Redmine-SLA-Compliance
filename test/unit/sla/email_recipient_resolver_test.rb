# frozen_string_literal: true

require_relative '../../test_helper'

class Sla::EmailRecipientResolverTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles

  test 'returns only configured active members of the target project' do
    project = Project.find(1)
    setting = SlaNotificationSetting.create!(scope_key: 'global')
    member = project.users.joins(:email_address).first
    outsider = User.active.joins(:email_address).where.not(id: project.users.select(:id)).first
    setting.replace_recipient_user_ids!(:at_risk, [member.id, outsider.id])

    resolved = Sla::EmailRecipientResolver.for(setting, channel: :at_risk, project: project)

    assert_equal [member.id], resolved.map(&:id)
  end
end
