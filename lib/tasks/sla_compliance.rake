# frozen_string_literal: true

# Manual / cron entry point for the at-risk & stale sweep.
# Usage:
#   bundle exec rake redmine_sla_compliance:sweep RAILS_ENV=production
#
# Runs the same Sla::Sweep the in-process scheduler runs, off the request path. Safe to run
# repeatedly (idempotent: it never re-queues an at-risk ticket). Provided so operators can trigger
# a sweep on demand, verify behaviour, or drive it from OS cron instead of the in-process scheduler.
namespace :redmine_sla_compliance do
  desc 'Re-evaluate open SLA-tracked tickets and queue at-risk notifications (idempotent)'
  task sweep: :environment do
    summary = Sla::Sweep.new.run
    puts "[SLA] sweep complete: #{summary.swept} swept, " \
         "#{summary.newly_at_risk} newly at-risk, #{summary.queued} queued."
  end
end
