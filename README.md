# Redmine SLA Compliance Plugin

Per-project SLA policies and automatic SLA-compliance measurement for incident tickets in
Redmine, presented as a filterable dashboard, with Google Chat + email notifications and a
live, time-aware dashboard state.

The plugin recomputes cached SLA projections whenever a ticket changes. While a dashboard is open,
it refreshes every 15 seconds and evaluates indexed `at_risk_at` / `breach_at` projections against
the current time. This keeps the visible dashboard current without a recurring server scheduler or
reconstructing ticket journals on dashboard reads. SLA timelines are reconstructed from Redmine's
journal history, never from the issue's current state.

See `SLA_Compliance_Plugin_Implementation_Plan.md` for the full spec and phased plan.

## Compatibility

| | Supported |
|---|---|
| Redmine | 5.1.x (developed against 5.1.4) |
| Ruby | 3.1.x |
| Rails | 6.1.x |

- **Background jobs:** ActiveJob using Redmine's configured adapter (default `:async`).
- **Live dashboard:** event-driven cache writes plus indexed, read-time state projections.

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

Phase 0 (setup & scoped UI foundation) is in place: loadable plugin, project module + the
`view_sla_dashboard` / `edit_sla_policy` / `manage_sla_notifications` permissions, and the scoped
Tailwind/Flowbite build with a Flowbite test page. Data model, engine, dashboard, and
notifications follow in later phases.
