# frozen_string_literal: true

# Admin CRUD for the Response/Workaround/Resolution duration lookup that populates the
# target dropdowns in the SLA policy form (Step 4.4). Global Rule 1: target option lists are
# admin-managed data, never code constants.
class SlaTargetOptionsController < ApplicationController
  layout 'admin'
  self.main_menu = false
  # This is a separate controller from SettingsController#plugin, so without this the admin
  # sidebar's :admin_menu highlighting (Redmine::MenuManager::MenuController#current_menu_item)
  # has no entry for it and "Plugins" loses its selected state while on this page — mirror
  # core's own `menu_item :plugins, :only => :plugin` (settings_controller.rb) so this page reads
  # as part of the same "Plugins" section.
  menu_item :plugins
  helper :sla_compliance

  before_action :require_admin
  before_action :find_target_option, only: [:edit, :update, :destroy]

  def index
    @target_options = SlaTargetOption.order(:target_type, :position, :seconds)
  end

  def new
    @target_option = SlaTargetOption.new(target_type: params[:target_type].presence)
  end

  def create
    @target_option = SlaTargetOption.new(target_option_params)
    if @target_option.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to sla_target_options_path
    else
      render :new
    end
  end

  def edit
  end

  def update
    if @target_option.update(target_option_params)
      flash[:notice] = l(:notice_successful_update)
      redirect_to sla_target_options_path
    else
      render :edit
    end
  end

  def destroy
    @target_option.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to sla_target_options_path
  end

  private

  def find_target_option
    @target_option = SlaTargetOption.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def target_option_params
    permitted = params.require(:sla_target_option)
                      .permit(:target_type, :code, :label, :seconds, :position, :best_effort, :basis)
    permitted[:seconds] = nil if ActiveRecord::Type::Boolean.new.cast(permitted[:best_effort])
    permitted
  end
end
