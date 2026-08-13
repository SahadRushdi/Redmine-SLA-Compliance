# Redmine SLA Compliance Plugin

Per-project SLA policies and automatic SLA-compliance measurement for incident tickets in
Redmine, presented as a filterable dashboard, with Google Chat + email notifications and a
time-aware dashboard state.

The plugin recomputes cached SLA projections whenever a ticket changes and schedules targeted
background transitions for projected `at_risk_at`, `breach_at`, and `stale_at` timestamps. At-risk
and stale email alerts are immediate and do not depend on a cron sweep; the dashboard evaluates
the indexed projections against the current time on every request. SLA timelines are reconstructed
from Redmine's journal history, never from the issue's current state.

See `SLA_Compliance_Plugin_Implementation_Plan.md` for the full spec and phased plan.

## Compatibility

| | Supported |
|---|---|
| Redmine | 5.1.x (developed against 5.1.4) |
| Ruby | 3.1.x |
| Rails | 6.1.x |

- **Background jobs:** ActiveJob with a durable production adapter and running worker. The default
  in-process `:async` adapter is suitable only for development because scheduled jobs are lost on
  restart.
- **Live calculations:** event-driven cache writes plus targeted background state transitions.
- **Post-upgrade/recovery:** run `redmine_sla_compliance:reconcile_live` once after deployment and
  after material queue downtime. The legacy `sweep` task remains an explicit maintenance tool,
  not a scheduler requirement.

## Install

```bash
# 1. Place this plugin under redmine/plugins/redmine_sla_compliance
# 2. Install gems
cd redmine && bundle install

# 3. Build the scoped Tailwind + Flowbite stylesheet (see below)
cd plugins/redmine_sla_compliance && npm install && npm run build

# 4. Run plugin migrations
cd ../.. && RAILS_ENV=production bundle exec rake redmine:plugins:migrate

# 5. Restart Redmine
```

Then enable the **SLA Compliance** module per project under *Project → Settings → Modules*.

## UI build (scoped Tailwind + Flowbite)

The plugin's CSS is compiled to a single scoped stylesheet that cannot leak into Redmine's own
styling: Tailwind **Preflight is disabled**, all utilities are **`tw-` prefixed**, and every
utility is scoped under a **`.sla-plugin`** wrapper. Flowbite JS loads only on plugin pages.

```bash
cd plugins/redmine_sla_compliance
npm install
npm run build     # one-off build -> assets/stylesheets/tailwind.output.css
npm run watch     # rebuild on change during development
```

## Status

Phases 0–8 are implemented, including cached SLA evaluation, live transitions, dashboards,
Google Chat notifications, at-risk email alerts/digests, and stale-ticket digests.
