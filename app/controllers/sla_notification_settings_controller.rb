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
    attributes, recipient_ids = extracted_params
    setting.assign_attributes(attributes)
    valid_ids = permitted_recipient_ids(recipient_ids.values.flatten)
    invalid_ids = recipient_ids.values.flatten.map(&:to_i).uniq - valid_ids
    setting.errors.add(:base, l(:error_sla_invalid_notification_recipients)) if invalid_ids.any?

    if setting.errors.empty? && save_with_recipients(setting, recipient_ids.transform_values { |ids| ids.map(&:to_i) & valid_ids })
      return render json: { message: l(:notice_successful_update) } if request.xhr? || request.format.json?
      flash[:notice] = l(:notice_successful_update)
    else
      error = setting.errors.full_messages.join(', ')
      return render json: { error: error }, status: :unprocessable_entity if request.xhr? || request.format.json?
      flash[:error] = setting.errors.full_messages.join(', ')
    end
    redirect_to redirect_path
  end

  def setting_params
    permitted = params.require(:sla_notification_setting)
                      .permit(:google_chat_webhook, :at_risk_email_enabled,
                              :at_risk_email_frequency, :at_risk_digest_interval_minutes,
                              :stale_email_enabled, :stale_email_frequency, :stale_threshold_days,
                              at_risk_email_recipient_user_ids: [],
                              stale_email_recipient_user_ids: []).to_h
    permitted
  end

  def extracted_params
    permitted = setting_params
    ids = {}
    { at_risk: 'at_risk_email_recipient_user_ids',
      stale: 'stale_email_recipient_user_ids' }.each do |channel, key|
      ids[channel] = Array(permitted.delete(key)).reject(&:blank?) if permitted.key?(key)
    end
    [permitted, ids]
  end

  def permitted_recipient_ids(requested)
    scope = @project ? Sla::ProjectRecipientUsers.for(@project) : User.active.joins(:email_address)
    scope.where(id: requested.map(&:to_i)).distinct.pluck(:id)
  end

  def save_with_recipients(setting, recipient_ids)
    SlaNotificationSetting.transaction do
      setting.save!
      recipient_ids.each { |channel, ids| setting.replace_recipient_user_ids!(channel, ids) }
    end
    true
  rescue ActiveRecord::RecordInvalid
    false
  end
end
