# frozen_string_literal: true

# Saves the notification section of the SLA Policy tab. Gated by
# :manage_sla_notifications (independent of :edit_sla_policy).
class SlaNotificationSettingsController < ApplicationController
  layout 'admin', only: :update_global
  self.main_menu = false
  menu_item :sla_compliance_settings

  before_action :find_project_by_project_id, only: :update
  before_action :authorize, only: :update
  before_action :require_admin, only: :update_global

  def update
    setting = SlaNotificationSetting.find_or_initialize_by(project_id: @project.id)
    save_setting(setting, settings_project_path(@project, tab: 'sla_policy'))
  end

  def update_global
    save_setting(SlaNotificationSetting.global_for_form,
                 sla_settings_path(section: 'notifications'))
  end

  private

  def save_setting(setting, redirect_path)
    setting.assign_attributes(setting_params)
    if setting.save
      flash[:notice] = l(:notice_successful_update)
    else
      flash[:error] = setting.errors.full_messages.join(', ')
    end
    redirect_to redirect_path
  end

  def setting_params
    permitted = params.require(:sla_notification_setting)
                      .permit(:google_chat_webhook, :at_risk_email_enabled,
                              :at_risk_email_frequency, :at_risk_digest_interval_minutes,
                              :stale_email_enabled, :stale_email_frequency, :stale_threshold_days,
                              at_risk_email_recipients: [], stale_email_recipients: []).to_h
    %w[at_risk_email_recipients stale_email_recipients].each do |key|
      permitted[key] = Array(permitted[key]).map(&:strip).reject(&:empty?) if permitted.key?(key)
    end
    permitted
  end
end
