# frozen_string_literal: true

# Saves the notification section of the SLA Policy tab. Gated by
# :manage_sla_notifications (independent of :edit_sla_policy).
class SlaNotificationSettingsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize

  def update
    setting = SlaNotificationSetting.find_or_initialize_by(project_id: @project.id)
    setting.assign_attributes(setting_params)

    if setting.save
      flash[:notice] = l(:notice_successful_update)
    else
      flash[:error] = setting.errors.full_messages.join(', ')
    end
    redirect_to settings_project_path(@project, tab: 'sla_policy')
  end

  private

  def setting_params
    permitted = params.require(:sla_notification_setting)
                      .permit(:google_chat_webhook, :at_risk_email_enabled,
                              :at_risk_email_frequency, :at_risk_digest_interval_minutes,
                              :stale_email_enabled, :stale_email_frequency,
                              at_risk_email_recipients: [], stale_email_recipients: []).to_h
    %w[at_risk_email_recipients stale_email_recipients].each do |key|
      permitted[key] = Array(permitted[key]).map(&:strip).reject(&:empty?) if permitted.key?(key)
    end
    permitted
  end
end
