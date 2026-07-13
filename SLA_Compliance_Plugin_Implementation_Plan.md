# Redmine SLA Compliance Plugin — Implementation Plan

> **How to use this document.** Each numbered **Step** is a self-contained unit of work. Do the steps **in order** — later steps depend on earlier ones. Read the **Global Rules** and the **State Model** before starting any step; they apply everywhere. Each step lists a **Goal**, **Build**, **Files**, **Done when** (acceptance criteria), and **Watch out for**. Do not begin a step until its dependencies (Appendix A) are complete.

---

## 0. What we are building  

A **Redmine plugin** (a Rails engine) that lets each customer project define SLA policies and automatically measures SLA compliance for Incident tickets, presented as a filterable dashboard. It warns the team before tickets breach, and sends notifications:

- **Google Chat** message when a new issue is created on an SLA-configured tracker.
- **Email alerts** for tickets approaching breach (at-risk) and for stale, untracked tickets.

Each Redmine project represents one customer; SLA terms differ per customer, so policies are per-project with parent→child inheritance.

**Source of truth for ticket timelines** is Redmine's journal history (`journals` / `journal_details`), not the issue's current state. The engine walks that history to know when a ticket entered a status or received its first comment.

**The plugin is both event-driven and time-driven.** Results update when a ticket changes (event-driven), but *at-risk* and *stale* status change purely as time passes with no ticket event — so a scheduled sweep re-evaluates open tickets on a timer.

---

## 1. Global Rules (apply to EVERY step)

1. **Nothing domain-specific is hard-coded.** No statuses, priorities, trackers, or severity labels as constants or enums. All are read live from the project's Redmine configuration, or stored as admin-editable settings.
2. **Reuse Redmine's existing objects.** Store references (tracker IDs, priority IDs, status IDs), never label strings. The Priority field is the severity indicator; do not create a new custom field.
3. **Support existing trackers.** The admin selects a tracker that already exists in the project; the plugin discovers that tracker's configured priorities and the project's statuses at runtime.
4. **Do not break or slow Redmine.** No core file edits — use hooks and the plugin API. SLA math is precomputed and cached, never computed on page load. Google Chat and email calls run asynchronously and must never block issue saving.
5. **Per-project, with parent→child inheritance.** A child project with no policy inherits its parent's effective policy.
6. **Configurable visibility.** Config and dashboard pages are gated by role; default Admin-only; an admin screen grants access to other roles.
7. **UI uses Tailwind + Flowbite**, compiled to a scoped stylesheet so it cannot leak into or break Redmine's existing styling. Charts use Chart.js with the Tableau 10 palette. Primary UI colour is blue.
8. **Test the engine.** The calculation engine (Phase 2) must have unit tests over hand-crafted journal histories before any UI or notification depends on it.
9. **Common legends, no duplicated text, sticky filters.** The dashboard reuses one shared legend across charts, avoids repeating labels, keeps the filter bar frozen on scroll, and shows selected filters as chips.

---

## 2. SLA State Model

Every SLA-tracked ticket resolves to one **primary state** plus an optional **at-risk flag**.

| Primary state | Meaning |
|---|---|
| **SLA met** | Not breached. Includes open tickets still within target **and** tickets resolved within target. |
| **SLA breached** | Exceeded a target (resolved late, or still open past target). |
| **No SLA** | Excluded from evaluation. Two sub-cases: **(a) SLA not configured** (project/tracker has no policy), **(b) not tracked** (priority = None/unclassified, or the relevant target is unset). |

**At-risk is a flag, not a primary state.** An open ticket that is still "SLA met" but within the configured at-risk threshold of breaching is flagged **at risk**. It remains inside the "SLA met" set for counting and is surfaced separately as an early-warning count.

**Reconciliation:** `Total = SLA met + SLA breached + No SLA`. At-risk is a subset of SLA met, reported alongside it — not added to the total.

**Labelling:** because open, un-breached tickets count as "met," the "% SLA met" figure includes tickets not yet resolved. The dashboard must label this clearly so it is not read as "% resolved successfully."

---

## 3. Fixed Decisions & Assumptions

Concrete choices so the engine is unambiguous. Where a value is configurable, the default is stated.

- **Reopened tickets restart the SLA clock from zero** (Re-opened is a "ticket created" status).
- **At-risk threshold is per-project configurable, expressed as a percentage of the target elapsed** (e.g. 80% = flag once 80% of the target time is used). This scales across short response targets and long resolution targets from a single setting.
- **First-response rule** is configurable per project: first comment, first status change, or whichever comes first. Private/internal notes do **not** count as a response.
- **Target option lists** (Response/Workaround/Resolution durations) are an admin-managed lookup, not code constants.
- **Sweep interval** (time-driven re-evaluation): every 15 minutes, configurable.
- **Google Chat webhook**: per-project setting, with a global fallback.
- **Email recipients**: a configurable list of email addresses per project.
- **"Stale" definition**: a ticket excluded from SLA with no comment or status change for a configurable period; digest sent on a configurable schedule (default weekly).
- **At-risk email frequency**: per project, either real-time (immediate on crossing the threshold) or digest (batched at a configurable interval, default hourly).
- **Time zone**: the Redmine instance time zone.
- **Historical recalculation** on policy save is optional (a checkbox) and unbounded by default.

---

## 4. Tech Stack

- **Backend:** Ruby on Rails engine (Redmine plugin), targeting the team's installed Redmine + Ruby version (confirm in Step 0.1).
- **Background & scheduled processing:** confirm what the instance supports (ActiveJob adapter, `delayed_job`, cron/`whenever`, or a Redmine scheduling gem). A recurring scheduler is required for the at-risk/stale sweep.
- **Frontend:** Tailwind CSS + Flowbite (scoped), Chart.js with the Tableau 10 palette.
- **Email:** Redmine's ActionMailer configuration.

---

# PHASE 0 — Setup & UI Foundation ✅Done

### Step 0.1 — Scaffold the plugin
- **Goal:** A loadable plugin that appears in Redmine's plugin list.
- **Build:** Generate the plugin skeleton with `init.rb` (name, author, version, Redmine version constraint). Confirm the installed Redmine and Ruby versions **and the available background + scheduling mechanism** before proceeding.
- **Files:** plugin root, `init.rb`, `README`.
- **Done when:** Redmine boots with the plugin installed; it shows in Administration → Plugins with no errors.
- **Watch out for:** version compatibility — verify against the actual instance, not the latest Redmine.

### Step 0.2 — Project module & permissions skeleton
- **Goal:** Register a project module and the permissions the rest of the plugin gates on.
- **Build:** In `init.rb`, declare a project module and named permissions (view dashboard, edit policy, manage notifications). Register menu items as stubs.
- **Done when:** The module is enablable per project under Settings → Modules; permissions appear under Administration → Roles.
- **Watch out for:** keep permission names stable — later steps reference them.

### Step 0.3 — Integrate Tailwind + Flowbite without breaking Redmine
- **Goal:** Tailwind utilities and Flowbite components usable on plugin pages only, with zero bleed into Redmine's UI.
- **Build:** Add a Tailwind CLI build step compiling one scoped stylesheet into the plugin's assets. **Disable Tailwind Preflight** (its global reset would wipe Redmine's styling), scope all plugin markup under a wrapper class (e.g. `.sla-plugin`), and prefix utilities (e.g. `tw-`). Load Flowbite JS only on plugin pages.
- **Files:** `tailwind.config.js`, plugin stylesheet, a plugin layout/partial, build script.
- **Done when:** A test page renders a styled Flowbite component **and** an existing Redmine page (e.g. the issues list) is visually unchanged.
- **Watch out for:** Preflight and Flowbite base styles are the top cause of "my plugin broke all of Redmine." Scope aggressively. Flowbite has no native tag-style multi-select; the status-chip inputs in later steps need a small companion library or a custom component — decide here.

---

# PHASE 1 — Data Model  ✅Done

### Step 1.1 — Migrations & models
- **Goal:** Tables and ActiveRecord models for the whole feature. All tables use an `sla_` prefix; all references to Redmine objects are stored as integer IDs.
- **Build:** Migrations for:
  - `sla_policies` — project_id, enabled, coverage_hours, business_calendar_id, first_response_rule, at_risk_threshold, pause flags.
  - `sla_definitions` — policy_id, tracker_id, priority_id, response/workaround/resolution targets (nullable = skipped).
  - `sla_status_mappings` — policy_id, role (created/work_started/resolved/pause), status_id.
  - `sla_business_calendars` — working days, hours, holidays.
  - `sla_results` — cache per issue: primary_state (met/breached/no_sla), at_risk (boolean), breach_at (projected breach time), response_seconds, resolution_seconds, deviation_seconds, calculated_at.
  - `sla_target_options` — admin-managed dropdown lookup (target_type, code, label, seconds).
  - `sla_notification_settings` — per project: google_chat_webhook, at-risk email (enabled, recipients, frequency, digest_interval), stale email (enabled, recipients, frequency).
  - `sla_notification_logs` — issue_id, target, notification_type, sent_at (dedup + digest batching).
- **Done when:** Migrations run clean up and down; models load with associations and validations.
- **Watch out for:** store IDs, never label strings. Index `sla_results` on `issue_id`, `project_id`, `primary_state`, `at_risk`, and `breach_at` (the sweep queries by projected breach time).

### Step 1.2 — Effective-policy resolution (inheritance)
- **Goal:** Given a project, return its effective policy, inheriting from the parent when none is set.
- **Build:** A resolver that walks up the project tree; a child with no policy uses the nearest ancestor's. Disabled policy = excluded.
- **Done when:** Unit tests cover own policy, inherited from parent, inherited from grandparent, none anywhere, disabled.

---

# PHASE 2 — Calculation Engine (build and unit-test before any UI depends on it) ✅Done

### Step 2.1 — Timeline reconstruction from journals
- **Goal:** For an issue, produce an ordered timeline of status transitions and comment events with timestamps from `journals` / `journal_details`.
- **Done when:** Unit tests reconstruct correct timelines from fixture issues, including reopened cases.

### Step 2.2 — Calendar-time elapsed calculation
- **Goal:** Compute elapsed wall-clock time between two events.
- **Done when:** Tested across day/month/DST boundaries.

### Step 2.3 — Business-hours calculation
- **Goal:** Compute elapsed working time using the project's business calendar (working days, hours, holidays).
- **Done when:** Tests cover spans crossing weekends, non-working hours, and holidays.
- **Watch out for:** the highest-bug-risk component. Test heavily and in isolation.

### Step 2.4 — Pause/exclusion handling
- **Goal:** Subtract time spent in configured pause statuses from Response/Workaround/Resolution time.
- **Done when:** Tests cover multiple pause intervals and a pause spanning a weekend (business-hours mode).

### Step 2.5 — First-response detection (configurable)
- **Goal:** Detect first response per the policy's configured rule (comment / status change / either), excluding private notes.
- **Done when:** Tests cover all three rules and private-note exclusion.

### Step 2.6 — Result classification
- **Goal:** Produce the primary state (met / breached / no_sla) plus deviation and projected breach time (`breach_at`) for open tickets. Open, un-breached tickets are `met`. Apply the No-SLA sub-cases (unconfigured vs not-tracked).
- **Done when:** Tests cover met (open + resolved), breached, and both No-SLA sub-cases.

### Step 2.7 — At-risk evaluation
- **Goal:** For an open, SLA-tracked ticket, determine whether it is within the at-risk threshold (percentage of target) of breaching any target, and compute `breach_at`. At-risk is a flag on a met ticket, not a distinct state.
- **Done when:** Tests cover on-track → at-risk → breached transitions for each target, in both calendar and business-hours modes.

### Step 2.8 — Stale-ticket detection
- **Goal:** For tickets excluded from SLA (unclassified priority or unset target), compute time since last activity (comment or status change).
- **Done when:** Tests return correct inactivity durations from fixtures.

---

# PHASE 3 — Precompute, Caching & the Time-Driven Sweep ✅Done

### Step 3.1 — Event-driven recompute
- **Goal:** Keep `sla_results` fresh when tickets change, without computing on page load.
- **Build:** On issue update (model hook), recompute that issue's cached result.
- **Done when:** Editing a ticket updates its cached result.

### Step 3.2 — Historical recalc on policy save
- **Goal:** Let admins optionally recalculate past tickets when a policy changes.
- **Build:** A "recalculate historical tickets" checkbox on policy save that enqueues a project recompute; default save is forward-only.
- **Done when:** With the tick, old tickets recompute; without it, they don't.

### Step 3.3 — Scheduled at-risk / stale sweep
- **Goal:** Periodically re-evaluate open SLA-tracked tickets so at-risk and stale states stay current without a ticket event.
- **Build:** A recurring job (interval from Step 0.1's scheduler) that refreshes open tickets' states via the engine, detects new at-risk transitions, and enqueues notification work (real-time send or digest accumulation) using `sla_notification_logs` for dedup. Also drives the stale-ticket digest schedule.
- **Done when:** A ticket crossing its at-risk window flips to at-risk in the cache within one interval and is queued for notification exactly once.
- **Watch out for:** idempotency — the sweep runs repeatedly; never double-send. This is the core architectural piece.

---

# PHASE 4 — SLA Policy Configuration UI

> Lives under **Project Settings → "SLA Policy" tab**, gated by the edit permission. Uses the scoped Tailwind/Flowbite setup from Step 0.3.

### Step 4.1 — Policy tab shell
- **Done when:** Tab appears for permitted roles only and loads the existing policy if present.

### Step 4.2 — Enable SLA + coverage + calendar
- **Build:** Toggle for SLA enabled; Coverage Hours dropdown (24×7×365 / Business Hours); Business Calendar selector shown only when Business Hours is chosen.
- **Done when:** Values persist; the calendar field is conditionally shown.

### Step 4.3 — Measurement rules
- **Build:** Chip multi-select inputs for Created / Work-started / Resolved statuses, populated from the project's actual statuses. First-response radio. At-Risk Threshold input (percentage). Empty status field = that milestone not evaluated.
- **Done when:** Selections persist as status IDs; the threshold persists.

### Step 4.4 — SLA definitions per Tracker × Priority
- **Build:** Tracker selector (existing trackers only). On selection, read that tracker's configured priorities for the project and render a target row per priority with Response/Workaround/Resolution dropdowns (values from the admin lookup). Unset = skipped. Priority "None" is excluded and shown as unclassified.
- **Done when:** Changing tracker re-renders the correct priority list dynamically; targets persist per tracker×priority.
- **Watch out for:** this is the heart of Global Rules 1–3. Nothing here may be hard-coded.

### Step 4.5 — Exclusions (pauses)
- **Build:** Chip multi-select for pause statuses, from the project's statuses. Empty = no pause.
- **Done when:** Pause statuses persist and feed Step 2.4.

### Step 4.6 — Notification settings
- **Build:** Per-project config for at-risk email (enable, recipients, real-time/digest + interval), stale-ticket email (enable, recipients, frequency), and the Google Chat webhook URL.
- **Done when:** Settings persist and are read by Phases 7–8.

### Step 4.7 — Clone policy
- **Build:** "Clone from another project" picker that pre-fills the form from a source project's policy for editing.
- **Done when:** Cloning populates all fields; saving creates an independent copy.

### Step 4.8 — Save behaviour + recalc tick
- **Build:** Wire save to forward-only by default plus the historical-recalc checkbox (links to Step 3.2).
- **Done when:** Save persists; tick enqueues historical recompute.

---

# PHASE 5 — Access Control

### Step 5.1 — Role-based visibility & edit
- **Goal:** Configurable who can view/edit config and dashboard; default Admin-only.
- **Build:** An admin screen (plugin settings) to grant view/edit/notification permissions to additional roles; enforce on every controller action.
- **Done when:** A non-permitted role sees neither the tab nor the dashboard; an admin can grant access to a chosen role and it takes effect.

---

# PHASE 6 — SLA Compliance Dashboard

> One dashboard with two access contexts: top-level (cross-project) and project-level. Reads only from the `sla_results` cache.

### Step 6.1 — Dashboard page + filters
- **Build:** Filters — Project (single/multi; defaults to SLA-enabled projects the user can access; project-level pre-selects and locks the current project when it has no sub-projects); Date Range (presets This Week, Last Week, This Month, Last Month, Last 3 Months, Custom; by created date); Tracker (SLA-configured trackers only); Priority (selected tracker's priorities). The filter bar is **sticky (frozen on scroll)**, shows **selected-filter chips**, and has a **Clear filters** action.
- **Done when:** Filters drive the query; context defaults apply; the bar stays pinned; chips reflect selection.

### Step 6.2 — Summary cards
- **Build:** Total tickets, % SLA met, % SLA breached, At risk (subset-of-met early-warning count), No SLA (not-configured vs not-tracked breakdown). Reconcile as `Total = met + breached + No SLA`; at-risk shown alongside met, not added to the total.
- **Done when:** Cards reconcile to the total; the "met" label makes clear it includes open, un-breached tickets.

### Step 6.3 — Charts
- **Build:** Compliance-split donut with three primary segments (SLA met / breached / No SLA) that sum to the total, with at-risk marked as a sub-band or marker inside the "met" portion (not a fourth slice); horizontal tickets-by-priority stacked bar; and a Created-vs-Resolved trend (dual line, Daily/Weekly/Monthly), where "Resolved" comes from the configured resolved-statuses. Use one shared legend across charts.
- **Done when:** Charts render from cache, share a common legend, and respond to filters.

### Step 6.4 — Detail table
- **Build:** Columns — ticket, project, tracker, title, status, assignee, first-response time, resolution time, result (SLA met / breached / No SLA, with an at-risk flag shown alongside the badge when applicable), deviation (breaches only). Sortable; filterable by state; rows open the ticket in a **new tab**.
- **Done when:** Sorting, filtering, and click-through all work; deviation shows only for breaches; at-risk appears as a flag on met rows, not as a replacement result.

---

# PHASE 7 — Google Chat Notification

### Step 7.1 — Notify Google Chat on issue creation
- **Goal:** Post a formatted message to a Google Chat webhook when an issue is created — only for SLA-configured trackers.
- **Build:** On issue create (model hook), fire an asynchronous POST to the webhook (from Step 4.6) with reference, title, type, priority, submitter, assignee, due date, and a link. Fire only when the issue's tracker is SLA-configured.
- **Done when:** Creating an issue on an SLA tracker posts the message; non-SLA trackers do not; a webhook failure logs an error but never blocks or delays issue creation.

---

# PHASE 8 — Email Notifications

### Step 8.1 — Email delivery foundation
- **Build:** Mailer(s) using Redmine's ActionMailer; recipient resolution from settings; asynchronous send; failures logged, not raised.
- **Done when:** A test email sends to the configured recipients without blocking anything.

### Step 8.2 — At-risk alerts (real-time + digest)
- **Goal:** Alert the team before a ticket breaches.
- **Build:** Driven by the sweep (Step 3.3): real-time sends immediately on an at-risk transition; digest batches at-risk tickets and sends every configured interval. Use `sla_notification_logs` to send once per ticket+target.
- **Done when:** A ticket crossing the threshold triggers exactly one real-time email (or appears once in the next digest), never duplicated across sweeps.

### Step 8.3 — Stale-ticket digest
- **Goal:** Surface excluded tickets (unclassified / unset target) that sit without activity.
- **Build:** A scheduled digest (frequency configurable, default weekly) listing title, status, created, last-updated, assignee, and project for stale tickets, sent to the configured recipients.
- **Done when:** The digest lists the correct stale tickets on schedule.

---

# PHASE 9 — Non-Functional Verification & Documentation

### Step 9.1 — Regression & performance check
- **Verify:** Existing trackers, workflows, and issue create/edit behave exactly as before. The dashboard reads from cache and stays responsive on a realistic dataset (thousands of tickets). The sweep and email jobs run off the request path. Tailwind/Flowbite styles remain scoped (no bleed).
- **Done when:** No measurable added latency on issue save; no visual regressions on core Redmine pages; sweeps complete within their interval.

### Step 9.2 — Docs & install notes
- **Build:** README with install steps, the Tailwind build step, supported Redmine version, scheduler setup for the sweep, and a configuration walkthrough.

---

## Appendix A — Dependency order

```
0.1 → 0.2 → 0.3
            ↓
1.1 → 1.2
   ↓
2.1 → 2.2 → 2.3 → 2.4 → 2.5 → 2.6 → 2.7 → 2.8   (engine, fully tested)
                                          ↓
3.1 → 3.2 → 3.3   (3.3 = time-driven sweep, needs 2.7 / 2.8)
   ↓
4.1 → 4.2 → 4.3 → 4.4 → 4.5 → 4.6 → 4.7 → 4.8   (4.8 needs 3.2)
   ↓
5.1
   ↓
6.1 → 6.2 → 6.3 → 6.4          (reads the phase-3 cache)
7.1                            (needs 4.6 webhook setting)
8.1 → 8.2 → 8.3                (needs 3.3 sweep + 4.6 settings)
   ↓
9.1 → 9.2
```
