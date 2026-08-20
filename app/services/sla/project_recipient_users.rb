# frozen_string_literal: true

module Sla
  class ProjectRecipientUsers
    def self.for(project)
      principal_ids = project.memberships.active.pluck(:user_id)
      direct_ids = User.active.where(id: principal_ids).pluck(:id)
      group_user_ids = Group.where(id: principal_ids).includes(:users).flat_map do |group|
        group.users.select(&:active?).map(&:id)
      end
      User.active.where(id: (direct_ids + group_user_ids).uniq).joins(:email_address).distinct
    end
  end
end
