# frozen_string_literal: true

# Admin CRUD for business calendars (working days / hours / holidays) used by business-hours
# coverage (Steps 2.3 / 4.2). Deleting a calendar still referenced by a policy is blocked by
# the model's dependent: :restrict_with_error.
class SlaBusinessCalendarsController < ApplicationController
  layout 'admin'
  self.main_menu = false
  # Keeps the "SLA Compliance" entry selected in the Administration sidebar while this page is
  # open. Redmine::MenuManager marks an admin_menu item selected when its NAME equals the
  # controller's `menu_item`, so every page of the module declares the same one — see
  # SlaSettingsController. (This used to be `:plugins`, back when the module's other pages were
  # hosted by SettingsController#plugin and that was the closest honest answer.)
  menu_item :sla_compliance_settings
  helper :sla_compliance
  # This page is one section of the SLA Compliance admin module and renders its shell, sidebar and
  # shared form/table partials — which live in SlaAdminHelper and (for the button/input/card
  # classes they share with the project-level policy form) SlaPoliciesHelper.
  helper :sla_admin
  helper :sla_policies

  before_action :require_admin
  before_action :find_calendar, only: [:edit, :update, :destroy]

  def index
    @calendars = SlaBusinessCalendar.order(:name)
  end

  def new
    @calendar = SlaBusinessCalendar.new
  end

  def create
    @calendar = SlaBusinessCalendar.new(calendar_params)
    if @calendar.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to sla_business_calendars_path
    else
      render :new
    end
  end

  def edit
  end

  def update
    if @calendar.update(calendar_params)
      flash[:notice] = l(:notice_successful_update)
      redirect_to sla_business_calendars_path
    else
      render :edit
    end
  end

  def destroy
    if @calendar.destroy
      flash[:notice] = l(:notice_successful_delete)
    else
      flash[:error] = @calendar.errors.full_messages.join(', ')
    end
    redirect_to sla_business_calendars_path
  end

  private

  def find_calendar
    @calendar = SlaBusinessCalendar.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # working_days posts as an array of ISO weekday numbers (checkboxes); holidays post as one value
  # per date from the chip input, normalised here into the model's JSON array.
  #
  # `holidays_text` is the form's older shape — a single textarea of one date per line. It is still
  # accepted so anything posting the old payload (a bookmarked form, a script) keeps working; the
  # chip input's `holidays[]` wins whenever it is present, which is on every submit from the
  # current form since it posts a blank sentinel even when the list is empty.
  def calendar_params
    permitted = params.require(:sla_business_calendar)
                      .permit(:name, :work_start_time, :work_end_time, :holidays_text,
                              working_days: [], holidays: []).to_h
    holidays_text = permitted.delete('holidays_text')
    permitted['working_days'] = Array(permitted['working_days']).map(&:to_i)

    raw_holidays = permitted.key?('holidays') ? Array(permitted['holidays'])
                                              : holidays_text.to_s.split(/[\r\n,]+/)
    permitted['holidays'] = raw_holidays.map { |day| day.to_s.strip }.reject(&:empty?)
    permitted
  end
end
