# frozen_string_literal: true

# Admin CRUD for business calendars (working days / hours / holidays) used by business-hours
# coverage (Steps 2.3 / 4.2). Deleting a calendar still referenced by a policy is blocked by
# the model's dependent: :restrict_with_error.
class SlaBusinessCalendarsController < ApplicationController
  layout 'admin'
  self.main_menu = false
  helper :sla_compliance

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

  # working_days posts as an array of ISO weekday numbers (checkboxes); holidays post as a
  # textarea of one ISO date per line, normalised here into the model's JSON array.
  def calendar_params
    permitted = params.require(:sla_business_calendar)
                      .permit(:name, :work_start_time, :work_end_time, :holidays_text,
                              working_days: []).to_h
    holidays_text = permitted.delete('holidays_text')
    permitted['working_days'] = Array(permitted['working_days']).map(&:to_i)
    permitted['holidays'] = holidays_text.to_s.split(/[\r\n,]+/).map(&:strip).reject(&:empty?)
    permitted
  end
end
