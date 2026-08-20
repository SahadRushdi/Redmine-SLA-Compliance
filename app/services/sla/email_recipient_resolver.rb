# frozen_string_literal: true

module Sla
  class EmailRecipientResolver
    def self.for(setting, channel:, project:)
      ids = setting.recipient_user_ids(channel)
      return User.none if ids.empty?

      ProjectRecipientUsers.for(project).where(id: ids).order(:lastname, :firstname, :id)
    end
  end
end
