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
5. **Per-project, with parent→child inheritance.** A child project with no policy inherits its parent's effective policy — including whether SLA is switched on. A child may override **only that on/off decision** (a tri-state: Inherit / Enabled / Disabled) while still following the parent's configuration, so later changes to the parent's coverage, targets and statuses keep reaching it. Overriding the *configuration* is a separate, heavier action that forks the policy — the child's settings tab shows every inherited value as an editable control (Step 6A.3), and saving any of it takes that fork.
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

**Open vs resolved.** A ticket is **open** until it enters one of the policy's configured `resolved`-role statuses — the same milestone that stops the SLA clock. This is deliberately *not* Redmine's `is_closed` flag: a "Resolved" status is commonly not `is_closed`, and a status Redmine calls closed may never have been mapped to the `resolved` role. The engine persists the resolution instant on every result (`sla_results.resolved_at`, nil ⇒ open, set for No-SLA tickets too) and that column is the single definition every reader uses — the dashboard's open-ticket population, the Stale card, and the sweep's "which tickets still need re-evaluating". Where no policy exists at all, and only there, Redmine's own `closed_on` is the fallback.

**Labelling.** The two questions the dashboard asks are not the same figure and must never share a word:
- Over the **open** population, "met" means *still inside its target* — it is a snapshot of the backlog, not an achievement. It is labelled **Within Target**.
- **% SLA met** is closed-loop: of the tickets **resolved** in a chosen period, how many met their target. Its denominator is the evaluated tickets only (met + breached); a resolved No-SLA ticket was never evaluated and must not dilute it.

**Two engine rules that qualify the table above:**
- **Live reclassification.** A cached `met` row whose projected `breach_at` has already passed is *reported* as breached by every reader (`Sla::EffectiveState`), without rewriting the cache. This keeps counts truthful between sweeps; the persisted state catches up on the next engine pass. At-risk gets no equivalent treatment — there is no precomputed instant to compare against — so it refreshes only on a full pass.
- **Best Effort.** A milestone marked Best Effort (Step 4A.1) is evaluated and its elapsed time reported, but it never breaches and is therefore never at-risk.

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

### Step 1.2a — Decision vs configuration (tri-state subproject enablement)
- **Goal:** Let a subproject switch SLA on or off for itself without forking the inherited policy (Global Rule 5).
- **Build:** A policy row carries two separable things, and inheritance resolves them independently. `sla_policies.inherits_config` (migration 005) marks a **lightweight row** that holds only the `enabled` decision. Resolution: the nearest row on the branch makes the decision; disabled still stops inheritance; an enabled self-defining row *is* the policy; an enabled lightweight row keeps its decision but takes its configuration from the nearest **self-defining** ancestor, whose own enabled flag is ignored because the descendant has explicitly overridden it. A lightweight row with no self-defining ancestor has nothing to measure against and resolves to nil. `config_source_for` (nearest self-defining row) is what the settings tab pre-fills its form from (Step 6A.3); `enablement_for` is the tri-state control's current selection. Saving any policy section clears `inherits_config`, since writing configuration is what makes a row self-defining.
- **Done when:** Unit tests cover a lightweight ENABLED row under a disabled ancestor, a lightweight DISABLED row under an enabled ancestor, a lightweight row inheriting configuration past an intermediate lightweight row, a lightweight row with no self-defining ancestor, and a self-defining row left unaffected.

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

# PHASE 4 — SLA Policy Configuration UI ✅Done

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
- **Build:** Tracker **multi-select** (existing trackers only). Each selected tracker gets its own Priority Targets table — a target row per active priority with Response/Workaround/Resolution dropdowns (values from the admin lookup) — and one Save writes them all. Unset = skipped. Priority "None" is excluded and shown once as an unclassified notice above the tables, never as a row with inputs.
- Field names nest under the tracker (`definitions[rows][<tracker>][<priority>][<type>]`) and the posted `definitions[tracker_ids][]` list is the authority for what may be written: rows for a tracker not in that list are ignored, and a tracker absent from the submit keeps its stored targets untouched. **The picker chooses what is on screen and therefore editable, not which trackers have an SLA** — clearing a tracker's targets is done by setting its rows to "not tracked", so hiding one can never be a silent delete.
- Adding a tracker fetches only that tracker's table and inserts it, rather than re-rendering the section, so targets already entered for the other selected trackers survive.
- **Done when:** several trackers can be configured and saved in one action; targets persist per tracker×priority; an unselected tracker's saved targets are unaffected.
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

# PHASE 4A — Policy UI Gaps Found in Client-Spec Review ✅Done

> Findings from re-reviewing the built Phase 4 UI against the client spec PDF and the running
> screenshots, plus a follow-up hardening pass on the Phase 3 fixes. All items below were
> triaged (verified against the codebase first, not blind-fixed) and are closed as of this
> section being added, with test coverage.

### Step 4A.1 — Best Effort + calendar/business target basis
- `sla_target_options` gained `best_effort` (bool) and `basis` ('calendar'|'business') columns.
  A Best Effort option has no `seconds` value and is never required to have one.
- `sla_definitions` gained per-milestone `*_best_effort` flags (snapshotted, consistent with the
  existing "snapshot the chosen value" design — never an FK back to the lookup).
- Engine: a Best Effort milestone is evaluated (elapsed time still reported) but never breaches
  and is never at-risk.
- A 'business'-basis target (e.g. "1 Business Day") paired with a `24x7x365`-coverage policy is
  rejected at save time (`SlaDefinition` validation) — it would otherwise silently be read as
  calendar time with no warning.
- **Done when:** Best Effort options are creatable and selectable per priority row; a Best
  Effort milestone never contributes to `breached`/`at_risk`; a business-basis target under
  24x7 coverage fails the save atomically with a clear error.

### Step 4A.2 — Inheritance banner + Override / Revert
> **Partly superseded by Step 6A.3.** The read-only summary and the Override button described
> here were replaced by a pre-filled editable form; Revert, and the reason the original blank
> form was a defect, still stand. Kept for the history of why the blank form was never acceptable.

- A project with no policy of its own but an inherited one now renders a **read-only summary**
  ("This project inherits its SLA policy from X") instead of the interactive form — the
  interactive form used to render blank in this case, and saving it silently created an empty
  override that disabled SLA for the child project.
- **Override for this project** unlocks the real form, prefilled from the ancestor's policy —
  implemented by reusing the existing Step 4.7 clone-prefill AJAX path with the ancestor as the
  source (no new prefill logic).
- **Revert to inherited policy** deletes the project's own policy row (cascading to its
  definitions/mappings) when both the project has its own row AND some further ancestor has one;
  it recalculates `sla_results` in place, never deletes the cache.
- `SlaPolicy.source_for(project)` (new) answers "which project does the displayed policy actually
  belong to" — reuses `effective_for`'s `self_and_ancestors` traversal rather than a second
  tree-walk.
- **Done when:** an inherited project never shows an editable blank form; Override prefills and
  requires an explicit Save; Revert is offered only when there's something to revert to and never
  deletes cached results.

### Step 4A.3 — Notification dedup hardening (Phase 3 follow-up)
Re-review of the Phase 3 fixes surfaced three problems in the fixes themselves, all closed here:
- The dedup unique index would have aborted on first run against any real (non-empty) database
  with pre-existing duplicate rows — migration now dedupes via
  `RedmineSlaCompliance::NotificationLogDeduplicator` before creating the index.
- The dedup key was a lifetime claim, which would have permanently blocked re-notification after
  a ticket resolves and reopens (a new SLA measurement cycle). A `cycle_key` column was added:
  for at-risk claims it's the engine's `cycle_started_at`; for stale-digest claims it's the
  claimed digest window's instant. A still-stale ticket now reappears in every digest window it
  qualifies for, not just once ever.
- The sweep itself had no cross-process claim, so every app-server worker ran the full sweep
  every interval. `SlaSweepState.claim_run!` (a conditional `UPDATE`, mirroring the stale-digest
  window claim) now lets only one worker actually run it per interval.
- Whether running the scheduler inside web-server worker processes (current approach, now
  correct under concurrency via the claim above) vs. an OS-cron-invoked rake task or a
  delayed_job-scheduled recurring job is the right long-term architecture for this Redmine
  instance is still an open deployment decision — see the comment in
  `lib/redmine_sla_compliance/sweep_scheduler.rb`. Not settled by this pass.

### Step 4A.4 — Sweep interval fully admin-configurable
`Sla::PluginSettings.sweep_interval_minutes`, read from Administration → Plugins → SLA
Compliance (default 15, clamped 1–1440). The scheduler ticks every 60s and only actually sweeps
once the currently-configured interval has elapsed, so a changed setting takes effect within a
minute — no app restart, no dynamic Rufus job rescheduling.

### Items reviewed and confirmed already correct (no change made)
- **At-risk threshold + first-response radio (4.3):** both already render, persist, and are
  tested — no gap found.
- **Digest interval field (4.6):** already exists as `at_risk_digest_interval_minutes`, correctly
  conditional on frequency=digest. Added a hint cross-referencing the global sweep interval
  rather than a hard validation — a short digest interval just batches at the sweep's cadence,
  it doesn't produce a wrong answer the way B4's basis mismatch did.
- **Status chip scoping:** deliberately project-wide (`Project#rolled_up_statuses`), not scoped
  to one tracker's workflow. `sla_status_mappings` is one row per (policy, role) — not per
  tracker — so narrowing to a single tracker's reachable statuses would incorrectly exclude
  statuses other trackers in the same project actually use. Redmine's own workflow model also
  has no tracker-only "reachable statuses" concept — reachability is always (tracker, role).
- **Select-dropdown "clipping" in the screenshots:** the compiled scoped Tailwind CSS has no
  `overflow-hidden`, fixed height, or line-clamp rule near any `<select>` — the screenshot in
  question shows the "No target duration options defined yet" empty state, which is the more
  likely explanation. Revisit with target options actually populated before treating this as a
  CSS bug.
- **Two Save buttons:** intentional — the policy and notification forms are gated by different
  permissions (`edit_sla_policy` vs `manage_sla_notifications`) and must stay independently
  submittable. Relabelled "Save Policy" / "Save Notification Settings" for clarity instead of
  merging the forms.

---

# PHASE 5 — Access Control ✅Done

### Step 5.1 — Role-based visibility & edit
- **Goal:** Configurable who can view/edit config and dashboard; default Admin-only.
- **Build:** An admin screen (plugin settings) to grant view/edit/notification permissions to additional roles; enforce on every controller action.
- **Done when:** A non-permitted role sees neither the tab nor the dashboard; an admin can grant access to a chosen role and it takes effect.

---

# PHASE 6 — SLA Compliance Dashboard

> One dashboard with two access contexts: top-level (cross-project) and project-level. Reads only from the `sla_results` cache.

### Step 6.1 — Dashboard page + filters
- **Build:** Filters — Project (single/multi; defaults to SLA-enabled projects the user can access; project-level pre-selects and locks the current project when it has no sub-projects); Date Range (presets This Week, Last Week, This Month, Last Month, Last 3 Months, Custom); Tracker (SLA-configured trackers only); Priority (the selected tracker's priorities, minus the admin's unclassified priority, and offered only once a tracker is chosen). The filter bar is **sticky (frozen on scroll)**, shows **selected-filter chips**, and has a **Clear filters** action.
- **Date Range scope:** Project/Tracker/Priority apply everywhere, but the date range does **not**. It scopes exactly two things: the **SLA Met** card (by resolution date) and the **Created-vs-Resolved trend** (which filters its two series against their own timestamp columns independently). Every open-ticket figure ignores it entirely — see Step 6.2.
- **Done when:** Filters drive the query; context defaults apply; the bar stays pinned; chips reflect selection; changing the date preset moves the SLA Met card and the trend chart and nothing else.

### Step 6.2 — Summary cards
The dashboard is split into two tabs because it answers two different questions, and mixing them was the defect this step now guards against.

- **Open Tickets tab — the current backlog, at all times.** Population: every **open** ticket (not resolved, per §2), scoped by Project/Tracker/Priority only. Cards: **Total Open Tickets**, **Stale** (open tickets with no activity past their project's inactivity threshold), **SLA Breached**, **At Risk**, **No SLA** (not-configured vs not-tracked breakdown). Reconcile as `Total Open = Within Target + SLA Breached + No SLA`; at-risk is a subset of Within Target, shown alongside it and never added to the total. A breach is a live problem regardless of when the ticket was raised, which is why no date filter reaches this tab.
- **SLA Trend tab — closed-loop compliance over a period.** The **SLA Met** card: of the tickets **resolved** inside the selected window, the share that met their target. Denominator is the evaluated tickets (met + breached) only. Open tickets never appear here.
- **Done when:** the Open Tickets cards reconcile to Total Open and do not move when the date preset changes; a resolved ticket leaves every open-ticket card and the detail table; the SLA Met card counts only tickets resolved in the window and excludes No SLA from its denominator; no label reads "SLA Met" over the open population.

### Step 6.3 — Charts
- **Build:** Compliance-split donut with three primary segments (Within Target / breached / No SLA) that sum to the total open tickets, with at-risk marked as a sub-band or marker inside the "within target" portion (not a fourth slice); horizontal tickets-by-priority stacked bar; and a Created-vs-Resolved trend (dual line, Daily/Weekly/Monthly), where "Resolved" comes from the configured resolved-statuses. Use one shared legend across charts.
- The donut and priority bar read the same open-ticket scope as the cards, so all three always agree. The trend chart is the exception: it is historical by nature and reads an unfiltered scope, applying its own created/resolved ranges.
- **Done when:** Charts render from cache, share a common legend, and respond to filters.

### Step 6.4 — Detail table
- **Build:** Columns — ticket, project, tracker, title, status, assignee, first-response time, resolution time, result (Within Target / SLA breached / No SLA, with an at-risk flag shown alongside the badge when applicable), deviation (breaches only). Sortable; filterable by state; rows open the ticket in a **new tab**. Same open-ticket scope as the cards. A CSV export emits every matching row under the same filters.
- **Done when:** Sorting, filtering, and click-through all work; deviation shows only for breaches; at-risk appears as a flag on within-target rows, not as a replacement result.

---

# PHASE 6A — Open-Ticket Semantics & Subproject Enablement ✅Done

> A second client pass on the built dashboard and settings tab. Two defects, both of which
> changed what the numbers *mean* rather than how they render, so §1, §2 and Steps 6.1/6.2
> above were amended rather than annotated here.

### Step 6A.1 — Tri-state SLA on/off for a subproject
- **The gap:** the only way for a child project to switch SLA off was **Override for this
  project**, which clones the ancestor's whole configuration. From that moment the child stopped
  tracking the parent's coverage, targets and status mappings — a policy fork was being used to
  express a one-bit decision.
- **Build:** `sla_policies.inherits_config` (migration 005) separates the enabled decision from
  the configuration; see Step 1.2a for the resolution rules. The inherited banner gains a
  three-way control — **Inherit from `<Ancestor>` (currently on/off) / Enabled / Disabled** —
  posting `section=enablement`, a controller path that writes only `enabled` and can delete the
  row, and that never reaches the field-writing path. Override stays exactly as it was, and is
  now unambiguously the heavier "fork the configuration" action.
- **Watch out for:** the enablement path must refuse a project that has a self-defining row of
  its own (it would strip the flag and orphan that row's definitions and status mappings), and
  must not seed ancestor scalars onto the lightweight row (it would stop being lightweight).
- **Done when:** the resolver tests in Step 1.2a pass; a child set to Disabled disappears from
  the dashboard while its parent is unaffected; a child set to Enabled under a disabled parent
  appears, still measured by the parent's configuration; Inherit clears the row.

### Step 6A.2 — Open = not resolved, and the date range stops leaking
- **The gap:** nothing in the dashboard scope filtered open vs closed, so every card, chart and
  detail row counted resolved tickets alongside open ones. Separately, the date range was applied
  to the SLA Met card by `issues.created_on` over each ticket's *current* state — which answered
  "of tickets created in this window, how many are currently within target", not a compliance
  figure.
- **Build:** `resolved_at` becomes the single definition of open (§2). The engine's `closed_at`
  walks an explicit ladder — a recorded transition into a `resolved`-role status, else the
  ticket sitting in one now (falling back to Redmine's `closed_on`, then to the last recorded
  activity, never to `now`, which would drift on every sweep), else Redmine's `closed_on` alone
  where no policy exists — and No-SLA results now carry it too. `Sla::DashboardScope` replaces
  its generic `date_range` with two purpose-named filters, `open_only` and `resolved_range`;
  `Sla::StaleSummary` moves onto the same definition. The sweep re-scopes off `Issue.open` for
  the same reason: a ticket Redmine calls closed but the policy never mapped to `resolved` still
  has a running clock and must keep being re-evaluated.
- **Watch out for:** `resolved_at` was added by migration 004 with no backfill and was never set
  on No-SLA rows, so the release needs a one-off `rake redmine_sla_compliance:recalculate_all`
  before the open-ticket counts are trustworthy.
- **Done when:** the Step 6.2 acceptance criteria hold, and unit tests cover every rung of the
  resolution ladder, both new scope filters, and a Redmine-closed-but-unresolved ticket still
  being swept.

### Step 6A.3 — A subproject edits the inherited policy directly
- **The gap:** Step 4A.2 fixed a blank editable form by making the inherited state read-only, which
  traded one problem for another. A subproject saw a summary rather than the settings themselves,
  and the only way to change anything was **Override** — a mode switch, in front of a confirm,
  before a single field could be touched. The values governing that project's tickets were never
  shown as the controls that produce them.
- **Build:** the inherited state renders the **same sidebar and the same sections** as the project
  it inherits from, every control pre-filled with the inherited value. `Sla::PolicyPrefill` (new,
  shared with Step 4.7's clone) builds the in-memory copy, keeping only references valid in this
  project — statuses it uses, trackers it has enabled. The read-only summary, the Override button
  and its confirm are gone: the form *is* the override, taken when a section is saved. A one-line
  notice above the sections says where the values come from and what saving will do.
- **The first save of any section forks the WHOLE inherited configuration**, then applies the
  posted section on top (`seed_scalars_from!` → `copy_configuration_from!`). Without
  this a sectioned save would write a row holding only that section's slice — saving General alone
  would leave a project with no milestone statuses and no targets, a policy measuring nothing,
  moments after it was fully covered. This applies to a **lightweight row** too: it exists but owns
  no configuration, so it forks on the same terms, keeping its own `enabled` decision.
- **Watch out for:** the tri-state control (Step 6A.1) replaces the plain SLA-tracking switch while
  the configuration is inherited, so exactly one on/off control is on the page — and it stays the
  way to turn SLA off *without* forking, which is the whole reason it exists.
- **Done when:** a subproject's tab shows every inherited value as an editable control; no field
  can be saved from a value the user was never shown; the first save of any section leaves the
  project with the complete configuration it had a moment earlier plus the change just made.

### Step 6A.4 — A new subproject arrives with the module enabled
- **The gap:** the policy is inherited but the **module** is not. Redmine gives a new subproject
  `Setting.default_projects_modules` regardless of its parent, and every SLA gate — the settings
  tab, the dashboard scope, the sweep — is `has_module(:sla_compliance)`. So a child could inherit
  a complete, enabled policy and still be invisible to the plugin until someone ticked a box in
  Settings → Modules. That was the last manual step in an otherwise automatic chain.
- **Build:** `RedmineSlaCompliance::Patches::ProjectsControllerPatch` prepends `#new` and calls
  `enable_module!(:sla_compliance)` when the requested parent (`params[:parent_id]`, or
  `params[:project][:parent_id]` on a re-render — the same two params, in the same order, as core's
  `parent_project_select_tag`) already has the module.
- **It sets a DEFAULT, nothing more.** `#create` is untouched, so the checkbox the user actually
  submitted always wins and unticking it sticks. An `after_create` callback would have overruled
  that choice with no way to refuse — "on by default, off if you say so" is the requirement, and
  only the form default satisfies both halves.
- Existing subprojects are covered by `rake redmine_sla_compliance:enable_module_on_subprojects`
  (`DRY_RUN=1` to preview), deliberately a task an operator runs rather than something the plugin
  does on its own: enabling a module changes which menus and tabs a project shows to everyone on
  it, and that is the instance owner's call, not a side effect of an upgrade.
- **Done when:** the checkbox is pre-ticked under an SLA-enabled parent, left alone under a parent
  without the module and for a top-level project, and an unticked box survives a failed create.

### Step 6A.5 — Settings-tab ordering
- **Sidebar:** General → **SLA Targets** → Measurement Rules → Exclusions → Notifications. SLA
  Targets is the section people come back to; measurement rules are set once and rarely revisited.
  `SlaPoliciesHelper::SECTIONS` is the single source of that order (its first entry is also where
  the tab opens), and `_form.html.erb` renders the panels in the same order — only one is visible
  at a time, so that is for the no-JS fallback and for reading the file, but a file whose order
  contradicts the nav is a trap.
- **SLA Targets section:** Project Selection → Clone Policy → Tracker Selection → one Priority
  Targets card per selected tracker. The clone source picker is split out of the Clone Policy card
  into its own **Project Selection** card: choosing a project is reversible and does nothing on its
  own, while Load discards everything currently entered in the section, so they now read as two
  steps rather than one control with a button beside it. Neither renders when the user has no
  clonable source project, exactly as before.
- `POLICY_SECTIONS` is an allow-list of section keys a submit may name; `SECTIONS` decides which
  are offered and in what order. The test pinning them together asserts **membership, not order**,
  so the sidebar can be reordered without touching the controller.

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
4A.1 → 4A.2 → 4A.3 → 4A.4   (gap-review hardening pass; 4A.3 revisits 3.1-3.3)
   ↓
5.1
   ↓
6.1 → 6.2 → 6.3 → 6.4          (reads the phase-3 cache)
7.1                            (needs 4.6 webhook setting)
8.1 → 8.2 → 8.3                (needs 3.3 sweep + 4.6 settings)
   ↓
9.1 → 9.2
```
