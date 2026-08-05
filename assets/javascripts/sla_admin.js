/* SLA Compliance ADMIN MODULE behaviour (Administration → SLA Compliance).
 *
 * Loaded by app/views/sla_admin/_shell.html.erb, i.e. on every page of the module: the plugin
 * settings form and the Target options / Business calendars CRUD screens. Everything here is
 * feature-detected off data- attributes, so a page that has no panels (or no chip input) simply
 * gets nothing bound — there is no per-page variant of this file.
 *
 * Kept separate from sla_policy_form.js, which is the project-level SLA Policy tab's script: the
 * two share a visual pattern, not a page, and merging them would load the policy form's tracker /
 * clone / definition-table logic on the admin screens for nothing.
 */
(function () {
  'use strict';

  // --- Sidebar section navigation --------------------------------------------------------------
  // Only the sections that live as PANELS on the settings page carry data-sla-admin-section and are
  // intercepted here. Target options and Business calendars are separate resources at their own
  // URLs; their sidebar links are left alone to navigate normally, and the server re-renders the
  // sidebar there with the correct entry active.
  //
  // Both panels stay in the DOM and only their visibility changes: Redmine's settings form posts
  // every field on the page in one submit, so a panel that had been removed rather than hidden
  // would post nothing and its settings would be cleared on the next Apply.

  function activateSection(key) {
    if (!key) { return; }

    document.querySelectorAll('[data-sla-admin-panel]').forEach(function (panel) {
      panel.classList.toggle('hidden', panel.getAttribute('data-sla-admin-panel') !== key);
    });
    document.querySelectorAll('[data-sla-admin-section]').forEach(function (link) {
      var active = link.getAttribute('data-sla-admin-section') === key;
      link.classList.toggle('is-active', active);
      link.setAttribute('aria-current', active ? 'page' : 'false');
    });

    // Tell the form which section is open, so SlaSettingsController#update can redirect back to it
    // — saving from Access control must not bounce the user to General.
    var sectionField = document.getElementById('sla-settings-section');
    if (sectionField) { sectionField.value = key; }

    // Keep the address bar on the open section too, so a reload or a bookmark lands back where the
    // user was rather than on the first panel.
    if (window.history && window.history.replaceState) {
      var url = new URL(window.location.href);
      url.searchParams.set('section', key);
      window.history.replaceState({}, '', url.toString());
    }
  }

  function bindSectionNav() {
    document.querySelectorAll('[data-sla-admin-section]').forEach(function (link) {
      link.addEventListener('click', function (event) {
        var key = link.getAttribute('data-sla-admin-section');

        // Never swallow a click we cannot honour. The panel this link names has to be ON THIS
        // PAGE; if it isn't, the link is a normal navigation to another page of the module and
        // must be left alone. The server already only marks links it means us to intercept (see
        // sla_admin/_nav.html.erb), so this is the same rule stated where the damage would be
        // done — preventDefault() with nothing to show in return is a dead sidebar, which is
        // exactly the bug this pair of guards exists to prevent.
        if (!document.querySelector('[data-sla-admin-panel="' + key + '"]')) { return; }

        // The link is a real href carrying ?section=..., which is what makes the module usable
        // with JavaScript off; with JS on we swap panels in place instead, so suppress it.
        event.preventDefault();
        activateSection(key);
      });
    });
  }

  // --- Conditional field blocks ----------------------------------------------------------------
  // A switch marked data-sla-reveals="key" shows/hides [data-sla-reveal="key"]. A leading "!"
  // inverts it: the block is shown while the switch is OFF. Same attribute convention as
  // sla_policy_form.js, with the inversion added for Best Effort, where the numeric duration field
  // is the thing that disappears when the switch goes on.

  function applyReveal(input) {
    var spec = input.getAttribute('data-sla-reveals');
    if (!spec) { return; }

    var inverted = spec.charAt(0) === '!';
    var key = inverted ? spec.slice(1) : spec;
    var show = inverted ? !input.checked : input.checked;

    document.querySelectorAll('[data-sla-reveal="' + key + '"]').forEach(function (block) {
      block.classList.toggle('hidden', !show);
    });
  }

  function bindReveals() {
    document.querySelectorAll('input[data-sla-reveals]').forEach(function (input) {
      input.addEventListener('change', function () { applyReveal(input); });
      // Re-assert on load: after a failed save the form comes back with the switch in whatever
      // state was posted, which need not match the server-rendered `hidden` class.
      applyReveal(input);
    });
  }

  // --- Tom Select controls ---------------------------------------------------------------------

  // See assets/javascripts/sla_tom_select.js: Redmine core's defaultFocus() focuses the first
  // visible text input on the page, which after init IS a Tom Select control, and openOnFocus then
  // leaves its list hanging open before the user has touched anything.
  function guard(instance) {
    return window.slaTomSelect ? window.slaTomSelect.guard(instance) : instance;
  }

  // Native <select> popups are OS-rendered and cannot be themed to match the rest of the scoped
  // Flowbite UI; Tom Select replaces them with the same styled dropdown used across the plugin.
  function initSingleSelects() {
    document.querySelectorAll('select[data-sla-select]').forEach(function (el) {
      if (!el.tomselect && window.TomSelect) {
        guard(new TomSelect(el, { create: false, allowEmptyOption: true }));
      }
    });
  }

  // A real calendar date, not merely something shaped like one — "2026-02-31" matches the regex
  // but is not a date, and the model would reject the whole record for it (Date.iso8601 raises).
  // Checking here means the chip is refused as you type instead of coming back as a save error.
  function isIsoDate(value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) { return false; }
    var parsed = new Date(value + 'T00:00:00Z');
    return !isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
  }

  // Free-entry chips for a list of ISO dates (the business calendar's holidays).
  function initDateChips() {
    document.querySelectorAll('select[data-sla-date-chips]').forEach(function (el) {
      if (el.tomselect || !window.TomSelect) { return; }

      guard(new TomSelect(el, {
        plugins: ['remove_button'],
        create: isIsoDate,
        createFilter: isIsoDate,
        persist: false,
        // Pasting a list (from the textarea this replaced, or a spreadsheet column) splits into
        // one chip per date rather than a single unusable chip.
        delimiter: ',',
        // Dates read as a list only when they're in order; the stored array's order is arbitrary.
        sortField: { field: 'text', direction: 'asc' },
        placeholder: el.getAttribute('data-sla-chip-placeholder') || ''
      }));
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    bindSectionNav();
    bindReveals();
    initSingleSelects();
    initDateChips();
  });
})();
