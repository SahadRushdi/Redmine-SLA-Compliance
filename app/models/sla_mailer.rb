# frozen_string_literal: true

class SlaMailer < Mailer
  helper :sla_compliance

  def at_risk_alert(user, issue, log)
    prepare_sla(user, issue.project)
    @issue, @log = issue, log
    @result = SlaResult.find_by(issue_id: issue.id)
    @issue_url = Rails.application.routes.url_helpers.issue_url(issue, ::Mailer.default_url_options)
    mail to: user, subject: l(:mail_subject_sla_at_risk, project: issue.project.name, issue: "##{issue.id}")
  end

  def at_risk_digest(user, project, logs)
    prepare_sla(user, project)
    prepare_digest(logs)
    mail to: user, subject: l(:mail_subject_sla_at_risk_digest, project: project.name)
  end

  def stale_digest(user, project, logs)
    prepare_sla(user, project)
    prepare_digest(logs)
    mail to: user, subject: l(:mail_subject_sla_stale_digest, project: project.name)
  end

  private

  def prepare_sla(user, project)
    @user, @project = user, project
  end

  def prepare_digest(logs)
    @logs = logs
    @issues = Issue.where(id: logs.map(&:issue_id)).includes(:project, :status, :priority, :assigned_to).index_by(&:id)
    @results = SlaResult.where(issue_id: logs.map(&:issue_id)).index_by(&:issue_id)
  end
end
