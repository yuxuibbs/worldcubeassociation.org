# frozen_string_literal: true

class DelegateReportsController < ApplicationController
  before_action :authenticate_user!

  private def competition_from_params
    if params[:competition_id]
      Competition.find(params[:competition_id])
    else
      DelegateReport.find(params[:id]).competition
    end
  end

  def show
    @competition = competition_from_params
    redirect_to_root_unless_user(:can_view_delegate_report?, @competition.delegate_report) && return

    @delegate_report = @competition.delegate_report
  end

  def edit
    @competition = competition_from_params
    redirect_to_root_unless_user(:can_edit_delegate_report?, @competition.delegate_report) && return

    @delegate_report = @competition.delegate_report
  end

  def update
    @competition = competition_from_params
    redirect_to_root_unless_user(:can_edit_delegate_report?, @competition.delegate_report) && return

    @delegate_report = @competition.delegate_report
    @delegate_report.current_user = current_user
    was_posted = @delegate_report.posted?
    if @delegate_report.update_attributes(delegate_report_params)
      flash[:success] = "Updated report"
      if @delegate_report.posted? && !was_posted
        # Don't email when posting old delegate reports.
        # See https://github.com/thewca/worldcubeassociation.org/issues/704 for details.
        if @competition.end_date >= DelegateReport::REPORTS_ENABLED_DATE
          CompetitionsMailer.notify_of_delegate_report_submission(@competition).deliver_later
          flash[:info] = "Your report has been posted and emailed!"
        else
          flash[:info] = "Your report has been posted but not emailed because it is for a pre June 2016 competition."
        end
        redirect_to delegate_report_path(@competition)
      else
        redirect_to delegate_report_edit_path(@competition)
      end
    else
      render :edit
    end
  end

  private def delegate_report_params
    params.require(:delegate_report).permit(
      :discussion_url,
      :schedule_url,
      :equipment,
      :venue,
      :organization,
      :incidents,
      :remarks,
      :posted,
    )
  end
end
