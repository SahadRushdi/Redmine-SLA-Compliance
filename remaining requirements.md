# Remaining Requirements — SLA Compliance Plugin (Phases 0–4 Review)

> **Update (same day):** All Phase 3 and Phase 4 issues identified below have been fixed and are
> covered by new/updated tests. See the "Fix Status" section at the end of each affected phase and
> the summary at the bottom. Full suite: **215 runs, 562 assertions, 0 failures, 0 errors.**

**Reviewed against:** `SLA_Compliance_Plugin_Implementation_Plan.md` (source of truth per CLAUDE.md) and
`Requirement Specification for SLA Compliance Plugin.pdf` (original client spec), cross-checked with the
five UI screenshots supplied.

**Test suite status:** `bundle exec rake redmine:plugins:test NAME=redmine_sla_compliance RAILS_ENV=test`
→ **174 runs, 479 assertions, 0 failures, 0 errors.** All green.

**Overall verdict:** Phases 0–2 are complete and correct. Phase 4 was essentially complete with one real
functional gap (Priority "None" exclusion) plus a Redmine data-model note. Phase 3 was not fully done —
the at-risk half was solid, but the stale-ticket digest scheduling was entirely missing, the sweep interval
was hardcoded instead of configurable, and there was a genuine notification-dedup race condition that the
plan explicitly warned about. **All four of these gaps have since been fixed** (see the "Fix status"
subsections below and the punch list at the end) and are covered by new/updated tests — the plugin is now
in a good state to proceed to Phase 5.

---

## Phase 0 — Setup & UI Foundation — ✅ COMPLETE

- `init.rb` registers the plugin, project module, and three permissions (`view_sla_dashboard`,
  `edit_sla_policy`, `manage_sla_notifications`) exactly as specified — names are stable and referenced
  consistently downstream.
- Tailwind build is correctly scoped: `prefix: 'tw-'`, `preflight: false`
  (`tailwind.config.js`), and `postcss-prefix-selector` wraps **every** compiled selector under
  `.sla-plugin` (`postcss.config.js`) — including Flowbite's own base/global styles, which a bare
  Tailwind `important` option would not have caught. This matches the CLAUDE.md theme-isolation rules.
- No hardcoded blue leakage found outside the primary color; Flowbite toggle explicitly overrides
  `focus:tw-ring-primary-300` rather than inheriting default Flowbite blue.

No outstanding items.

---

## Phase 1 — Data Model — ✅ COMPLETE

- All eight tables from Step 1.1 exist with the `sla_` prefix, integer references (never label strings),
  and the exact indexes the plan calls for on `sla_results` (`issue_id`, `project_id`, `primary_state`,
  `at_risk`, `breach_at`).
- `SlaPolicy.effective_for` (Step 1.2) correctly walks the project tree: own → nearest ancestor →
  disabled-stops-inheritance → nil. Verified by `test/unit/effective_policy_resolver_test.rb` against all
  five plan-specified scenarios (own, parent, grandparent, none, disabled) plus two extra cases (nearest
  wins over a further enabled ancestor; disabled parent blocks an enabled grandparent).

No outstanding items.

---

## Phase 2 — Calculation Engine — ✅ COMPLETE (two minor test gaps)

All eight steps (2.1–2.8) are implemented and unit-tested in isolation per the CLAUDE.md testing
convention, with no database/controller involvement. Global Rules and the SLA State Model are honored
throughout:

- No domain-specific hardcoding anywhere in `app/services/sla/*.rb` (verified by grep) — statuses are
  resolved via the admin-configured `SlaStatusMapping` roles, not literal IDs.
- Reopened tickets restart the SLA clock from zero, driven by the same status-role mapping, not a
  hardcoded "Reopened" status (`result_classifier.rb:139-146`, tested).
- `primary_state` is strictly `met` / `breached` / `no_sla`; `at_risk` is a boolean field, never a fourth
  state (`result_classifier.rb:50,54,88-96`).
- Both No-SLA sub-cases (`not_configured`, `not_tracked`) are implemented and independently tested.

**Test gaps (not correctness bugs — just missing coverage):**
- `test/unit/sla/at_risk_evaluator_test.rb` has no business-hours **breached** case — only on-track and
  at-risk are exercised under business-hours mode. The calendar-mode suite has the breached case; the
  business-hours equivalent is missing.
- `test/unit/sla/result_classifier_test.rb` has exactly one business-hours test (`:183-206`), and it is a
  "met, not at-risk" scenario only — no business-hours "met + at-risk" or "breached" case at the
  full-pipeline level.

Recommendation: add the missing business-hours-breached test cases to close out Step 2.7's literal
"Done when" wording ("in both calendar and business-hours modes").

---

## Phase 3 — Precompute, Caching & the Time-Driven Sweep — ⚠️ PARTIAL

### Step 3.1 — Event-driven recompute — ✅ COMPLETE
`issue_patch.rb:17` hooks `after_commit on: %i[create update]`, gated on the module being enabled, wrapped
in `rescue StandardError` so a recompute failure can never break issue save. Well tested.

### Step 3.2 — Historical recalc on policy save — ✅ COMPLETE
The "recalculate historical tickets" checkbox genuinely gates an async `SlaPolicyRecalculationJob.perform_later`
call; unticked saves are proven forward-only by test. `ProjectRecalculator` streams via `find_each` across
`self_and_descendants`, avoiding memory bloat.

### Step 3.3 — Scheduled at-risk/stale sweep — ❌ NOT DONE (three distinct gaps)

This is the step the plan itself calls "the core architectural piece," and it's the one place real gaps
were found:

**1. Stale-ticket digest scheduling is entirely missing.**
Step 2.8's `StaleTicketDetector` service exists and is correctly unit-tested in isolation, but it is
**never called from `Sweep`, any job, or the scheduler** — confirmed by grep across `app/` and `lib/`.
`Sla::Sweep#run` only iterates `project.issues.open` and only checks `newly_at_risk?`
(`sweep.rb:32-50,73-75`). No `sla_notification_logs` row of type `'stale'` is ever created in production
code. Step 3.3's own text explicitly requires this ("Also drives the stale-ticket digest schedule") — it
is unimplemented, not merely deferred to a later phase.

**2. Sweep interval is hardcoded, not configurable.**
Plan §3 (Fixed Decisions): "Sweep interval ... every 15 minutes, **configurable**." Actual:
`lib/redmine_sla_compliance/sweep_scheduler.rb:15` — `SWEEP_CRON = '*/15 * * * *'` is a fixed Ruby
constant with no admin/global setting behind it. The existing test
(`sweep_scheduler_test.rb:20-22`) only asserts this constant's value, effectively enshrining the
hardcoding rather than testing configurability.

**3. Notification dedup has a real race condition — exactly the risk the plan called out.**
`Sweep#queue_at_risk` (`sweep.rb:56-64`) is a check-then-act: `SlaNotificationLog.already_sent?`
(a plain `.exists?`) followed by a separate `.create!` — no `find_or_create_by!`, no transaction, no
locking. The backing index is **not unique**
(`db/migrate/001_create_sla_compliance_tables.rb:144-145`, `idx_sla_notification_logs_dedup` has no
`unique: true`), and there's no model-level uniqueness validation either. This matters because
`RedmineSlaCompliance::SweepScheduler.start` (`init.rb:70`) runs unconditionally in every app-server
worker process (`Rails.application.config.after_initialize`), and each worker's Rufus::Scheduler instance
is process-local. In any multi-process deployment (Puma cluster mode, Passenger, Unicorn — the norm for
production Rails), N workers independently fire the same `*/15 * * * *` cron and race on the same dedup
check. The cron job also has no `:overlap => false` guard, so even a single worker could re-enter the
sweep if one run overruns 15 minutes. The plan's explicit instruction — "race-condition-safe e.g. via a
unique index / find_or_create pattern, not just an app-level check-then-act" — is precisely the gap here.
The existing "exactly-once" tests only exercise a single in-process, single-threaded sweep, so they cannot
catch this.

**What is solid in 3.3:** the at-risk half of the sweep logic itself — iterating SLA-enabled projects,
recomputing open issues, detecting `newly_at_risk?` transitions — is well built and the exactly-once
behavior is proven for the single-process case (`sweep_test.rb:70-93,97-107`).

#### Fix status — all three gaps closed

1. **Dedup race — fixed.** Migration `002_add_sla_notification_dedup_and_stale_digest_fields.rb`
   backfills `sla_notification_logs.target` from NULL to `''` (a non-null sentinel — MySQL/Postgres
   both treat NULL as distinct from NULL in a unique index, so a nullable column would have silently
   defeated the fix) and replaces the old non-unique index with a genuine unique index on
   `[issue_id, notification_type, target]`. `SlaNotificationLog.claim!` replaces the
   check-then-act (`already_sent?` + `create!`) with a single `create!` that relies on the DB
   constraint, rescuing `ActiveRecord::RecordNotUnique` — so concurrent callers across any number of
   app-server processes can never both win. `Sweep#queue_at_risk` now calls `claim!` directly.
   The Rufus job also now runs with `overlap: false` (see point 3). Tested in
   `test/unit/sla_notification_log_test.rb`, including a test that bypasses `claim!` entirely and
   inserts directly via raw SQL twice to prove the *database*, not just the Ruby method, rejects the
   duplicate.
2. **Stale-ticket digest — wired in.** `Sla::Sweep#run` now also tracks `no_sla/not_tracked` open
   issues per project (Step 2.8's exact scope — `not_configured` issues are deliberately excluded,
   matching the step's literal wording), and gates queuing through a new atomic schedule gate,
   `SlaNotificationSetting.claim_stale_digest_window!` — a conditional `UPDATE ... WHERE
   last_stale_digest_at IS NULL OR last_stale_digest_at <= cutoff`, the same DB-constraint pattern as
   the at-risk fix, keyed on the project's configured `stale_email_frequency`. A new
   `stale_threshold_days` field (migration 002, exposed in the notification settings form) supplies
   the separate "configurable period of inactivity" the plan calls for (distinct from the digest
   *send* frequency, which already existed). A new `Sla::StaleNotifier` mirrors `AtRiskNotifier`'s
   Phase-8-placeholder pattern. Tested in `sweep_test.rb` (six new tests): threshold crossing,
   below-threshold exclusion, disabled-project skip, `not_configured` exclusion, the digest window
   staying closed until its frequency elapses, and no double-queuing within one window.
3. **Sweep interval — now admin-configurable, no restart required.** New
   `Sla::PluginSettings.sweep_interval_minutes` reads `Setting.plugin_redmine_sla_compliance`
   (default 15, clamped to 1–1440). `SweepScheduler` was redesigned: instead of a fixed
   `*/15 * * * *` Rufus cron job that would need risky dynamic unscheduling to pick up a changed
   interval, it now runs a lightweight 60-second "tick" (`overlap: false`) that only actually invokes
   `Sla::Sweep` once the *currently configured* interval has elapsed since the last run — so an
   admin's change takes effect on the very next tick. A new field ("Sweep interval (minutes)") was
   added to the plugin's global settings screen (Administration → Plugins → SLA Compliance). Tested
   in the rewritten `test/unit/sla/sweep_scheduler_test.rb` (interval read/default/clamp, `due?`/
   `tick!` behavior, and that a shortened interval takes effect without rescheduling the Rufus job)
   and `test/unit/sla/plugin_settings_test.rb`.

Multi-process duplicate *sweep work* (each app-server worker still runs its own copy of the sweep on
its own schedule) is an accepted, intentional tradeoff — it's wasted computation, not a correctness
bug, since `ResultStore.recalculate` is an idempotent upsert and both notification paths are now
DB-constraint-safe regardless of how many processes race on them. A distributed cross-process lock
would only be worth adding if the duplicate work itself becomes a measurable cost.

### Phase 7/8 boundary — clean
`AtRiskNotifier#enqueue_at_risk` is correctly stubbed to a log line only, explicitly documented as a
Phase 8 placeholder. No premature Google Chat or ActionMailer delivery code exists anywhere — Phase 3
correctly stops at "enqueue," it just doesn't yet enqueue stale-ticket work at all.

**Recommendation before calling Phase 3 done:**
1. Wire `StaleTicketDetector` into the sweep (or a sibling scheduled task) so stale tickets are actually
   found and logged/queued on the configured `stale_email_frequency` schedule.
2. Make the sweep interval read from a plugin setting (global, per Global Rule 6/Fixed Decisions) instead
   of the `SWEEP_CRON` constant.
3. Fix the dedup race: add a real unique index on `[:issue_id, :notification_type, :target]` and switch
   `queue_at_risk` to `find_or_create_by!`/`create!` + rescue `ActiveRecord::RecordNotUnique`, and/or add
   `:overlap => false` to the Rufus cron registration. This is worth prioritizing — it's the exact failure
   mode ("never double-send") the plan flags as the highest risk in this step.

---

## Phase 4 — SLA Policy Configuration UI — ✅ MOSTLY COMPLETE (one real gap)

Steps 4.1, 4.2, 4.3, 4.5, 4.6, 4.7, and 4.8 are all complete, well tested, and correctly avoid
hardcoding — statuses come from `project.rolled_up_statuses`, trackers from `project.trackers`, and
target durations from the admin-managed `SlaTargetOption` lookup (confirmed no hardcoded "1 Hour / 4
Hour / …" list anywhere in the view or controller layer). Notification recipient parsing is real
(TomSelect + email-regex filter client-side, `strip`/reject-blank + model validation server-side), and
Clone Policy genuinely deep-copies definitions and mappings into independent new rows rather than sharing
references.

### Step 4.4 — SLA definitions per Tracker × Priority — ⚠️ PARTIAL

Two findings here, the heart of Global Rules 1–3:

**1. Real gap — Priority "None" is not excluded.**
Both source documents agree on this: the plan says *"Priority 'None' is excluded and shown as
unclassified"*, and the spec PDF's terminology table says the same (*"None → Unclassified → Excluded from
SLA compliance calculation..."*). The current view (`app/views/sla_policies/_definition_rows.html.erb:5`)
lists every `IssuePriority.active` row identically, including one named "None" — an admin can currently
set Response/Workaround/Resolution targets against "None" like any other priority, and the engine would
then evaluate it normally instead of forcing `no_sla / not_tracked`. No code, locale key, or test
anywhere references a "None"/unclassified priority by name. This is a genuine unimplemented requirement,
not a deferred one — it's explicitly called for by both documents. (It sits in tension with Global Rule 1
against hardcoding severity labels; the code currently resolves that tension entirely in Global Rule 1's
favor, leaving the "None" carve-out undone. Worth a deliberate decision either way rather than leaving it
silent.)

**2. Data-model note, not a bug — "tracker's configured priorities" isn't a real Redmine concept.**
Redmine 5.1 core has no `Tracker` ↔ `IssuePriority` association — priorities are one global list. Both
the plan (Step 4.4: *"read that tracker's configured priorities"*) and the PDF (*"reads the Priority
options configured on that tracker"*) describe something Redmine doesn't actually support. The code
correctly falls back to the only real source, `IssuePriority.active`, so the priority list is identical
regardless of which tracker is selected — only the saved target values differ per tracker. This is the
correct engineering resolution given Redmine's actual data model, but it's a deviation from the literal
spec wording worth being aware of, not something to "fix."

**Recommendation:** decide how to handle Priority "None" — either special-case it out of the
`_definition_rows` list and force it into `no_sla/not_tracked` classification regardless of what's saved,
or explicitly document that it's intentionally treated like any other priority and update the plan/spec.
Given both source documents agree on exclusion, special-casing "None" is the more spec-faithful choice.

#### Fix status — implemented via a new admin-configurable global setting

Rather than hardcoding a string match on the literal name "None" (which would only work for this one
customer's enumeration data and would itself be a Global Rule 1 violation), the fix adds a new global
setting, `Sla::PluginSettings.unclassified_priority_id`, read from
`Setting.plugin_redmine_sla_compliance` (Administration → Plugins → SLA Compliance → "Unclassified
priority" dropdown, listing every `IssuePriority`). It stores an **ID**, per Global Rule 2 — never a
label — and defaults to auto-detecting a priority literally named "None" (case-insensitively) only
when the admin hasn't explicitly picked one, giving zero-config-correct behavior for the reference
customer setup while remaining fully overridable (or clearable) for any other instance.

This is enforced in three places:
- **Engine** — `Sla::PolicyContext#definition_for` returns `nil` whenever the requested priority is
  the configured unclassified one, *even if a stray `SlaDefinition` row exists for it* (e.g. data
  saved before this fix), forcing `no_sla/not_tracked` unconditionally.
- **UI** — `_definition_rows.html.erb` renders that priority's row disabled, with an "Unclassified"
  badge and no target dropdowns, so it can't be configured going forward.
- **Controller** — `SlaPoliciesController#replace_tracker_definitions!` and `#apply_clone_source!`
  both reject/skip that priority server-side (defense in depth against a forged submission or a
  clone-copy from a source project's legacy data).

Tested in `test/unit/sla/plugin_settings_test.rb` (auto-detect, explicit override, no-match-nil),
`test/unit/sla/policy_context_test.rb` (definition exclusion even with a stray saved row), and two new
functional tests in `sla_policies_controller_test.rb` (posted-row rejection, clone-skip).

---

## Priority-Ordered Punch List

1. ~~**[Phase 3, high]** Fix the notification-dedup race~~ — **FIXED.** Unique index (migration 002) +
   `SlaNotificationLog.claim!` atomic create.
2. ~~**[Phase 3, high]** Wire the stale-ticket digest into the sweep~~ — **FIXED.** `Sla::Sweep` now
   detects and queues stale tickets, gated per-project by an atomic schedule claim.
3. ~~**[Phase 3, medium]** Make the sweep interval configurable~~ — **FIXED.** Admin-configurable via
   Administration → Plugins → SLA Compliance, live-applied within 60 seconds, no restart.
4. ~~**[Phase 4, medium]** Implement Priority "None" exclusion~~ — **FIXED.** New
   `unclassified_priority_id` global setting (ID-based, auto-detected default), enforced in the
   engine, UI, and controller.
5. **[Phase 2, low, not yet addressed]** Add business-hours "breached" test cases to
   `at_risk_evaluator_test.rb` and `result_classifier_test.rb` to fully satisfy Step 2.7's stated
   acceptance criteria. Out of scope for this fix pass (Phase 2 wasn't reported as broken) — left
   here as a follow-up.
6. **[Phase 4, low, not yet addressed]** Add a Phase-4-level regression test confirming an empty
   pause-status list round-trips through the UI form into "no pause" behavior. Also left as a
   follow-up; the engine-level guard itself is correct and tested at the Phase 2 layer.

**Current state:** all four Phase 3/4 gaps from the original review are fixed, tested, and verified
against the live test database (migration applied cleanly, forward and idempotent-safe on re-run;
full suite green at 215 runs / 562 assertions / 0 failures). Items 5–6 are minor test-coverage
follow-ups, not functional defects, and were not part of this fix pass.

**Not yet done:** the migration has only been run against the `test` database in this session — it
has not been applied to `development`/production. Run
`bundle exec rake redmine:plugins:migrate NAME=redmine_sla_compliance RAILS_ENV=<env>` for whichever
environment(s) need it next; this was deliberately left for the user to trigger given the
live-instance handling conventions for this project.
