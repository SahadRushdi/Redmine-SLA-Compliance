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

  # Post-deploy backfill. Required once after the release that made the dashboard count OPEN
  # tickets only, because "open" is `sla_results.resolved_at IS NULL` and that column has never
  # been fully populated: migration 004 added it with no backfill (rows fill in lazily on their
  # next recompute), and until this release it was left nil on every No-SLA row. Without a pass,
  # long-resolved tickets keep counting as open.
  #
  # Reuses Sla::ProjectRecalculator rather than a bespoke loop, so the backfill runs the exact same
  # engine path a policy save does. Idempotent — an UPDATE per issue, safe to re-run. Runs off the
  # request path; expect it to take a while on a large instance.
  #
  # Scoped to module-enabled projects with `include_descendants: false`, which visits each of them
  # exactly once. Descending from roots instead would both double-recompute nested projects and
  # miss a module-enabled child of a root that has the module off — and the set maintained by the
  # event hook and the sweep is precisely "module enabled", nothing wider.
  desc 'Recompute the sla_results cache for every SLA-enabled project (idempotent; run once after upgrading)'
  task recalculate_all: :environment do
    projects = Project.active.has_module(:sla_compliance).to_a
    total = projects.sum { |project| Sla::ProjectRecalculator.run(project, include_descendants: false) }
    puts "[SLA] recalculation complete: #{total} issues recomputed across #{projects.size} project(s)."
  end
end
