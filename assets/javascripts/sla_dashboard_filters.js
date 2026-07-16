/* SLA dashboard filter bar behaviour (Step 6.1). Plain GET filter form — this file only handles
 * cosmetics (Tom Select chip/single-select rendering, toggling the custom date-range fields, and
 * the Datepicker) on top of a form that already works with plain <select>/<input> elements with
 * no JS at all. Idempotent init(), delegated handlers, matching sla_policy_form.js's shape. */
(function () {
  'use strict';

  var AUTO_APPLY_DEBOUNCE_MS = 700;
  var state = { bound: false, debounceTimer: null };

  function byId(id) { return document.getElementById(id); }

  function submitFormFor(el) {
    var form = el.closest ? el.closest('form') : el.form;
    if (!form) { return; }
    (form.requestSubmit ? form.requestSubmit() : form.submit());
  }

  // Auto-apply (no Apply/Clear buttons - matches the time_analytics plugin's own auto-apply
  // convention). Single-value controls (Tracker) submit the instant they change - same as the
  // Date Range pills below. Multi-selects (Project, Priority) and the custom date inputs debounce
  // briefly instead of submitting on every individual chip add/remove or keystroke, so picking
  // several values (or filling both From/To) doesn't navigate away mid-selection.
  function submitImmediately() {
    submitFormFor(this);
  }

  function submitDebounced() {
    var el = this;
    if (state.debounceTimer) { clearTimeout(state.debounceTimer); }
    state.debounceTimer = setTimeout(function () { submitFormFor(el); }, AUTO_APPLY_DEBOUNCE_MS);
  }

  // Same pattern as sla_policy_form.js's initChips/initSingleSelects (chip multi-selects vs.
  // single-value dropdowns styled to match the rest of the scoped Flowbite UI).
  function initChips() {
    document.querySelectorAll('select[data-sla-chips]').forEach(function (el) {
      if (!el.tomselect && window.TomSelect) {
        new TomSelect(el, { plugins: ['remove_button'] });
      }
    });
  }

  function initSingleSelects() {
    document.querySelectorAll('select[data-sla-select]').forEach(function (el) {
      if (!el.tomselect && window.TomSelect) {
        new TomSelect(el, { create: false, allowEmptyOption: true });
      }
    });
  }

  function toggleCustomRange() {
    var preset = byId('sla-filter-date-preset');
    var field = byId('sla-custom-range');
    if (!preset || !field) { return; }
    field.classList.toggle('hidden', preset.value !== 'custom');
  }

  // Date Range pill button-group (Figma). The buttons are a purely visual/interaction layer over
  // the real `#sla-filter-date-preset` <select>, which stays in the DOM (visually hidden) so the
  // existing controller param/validation and functional-test assertions on that element are
  // untouched. Clicking a non-custom preset submits immediately - matches the reference design
  // (no separate "Apply" step for a date range change); clicking "Custom Range" only reveals the
  // custom-range date inputs so the user can fill them in before submitting.
  function selectDatePreset(btn) {
    var select = byId('sla-filter-date-preset');
    if (!select) { return; }

    var value = btn.getAttribute('data-sla-preset-btn');
    select.value = value;
    toggleCustomRange();
    markActivePresetButton(btn);

    if (value !== 'custom') {
      var form = select.closest('form');
      if (form) { (form.requestSubmit ? form.requestSubmit() : form.submit()); }
    }
  }

  function markActivePresetButton(activeBtn) {
    document.querySelectorAll('[data-sla-preset-btn]').forEach(function (btn) {
      var active = btn === activeBtn;
      btn.classList.toggle('tw-bg-primary-600', active);
      btn.classList.toggle('tw-text-white', active);
      btn.classList.toggle('tw-border-primary-600', active);
      btn.classList.toggle('tw-bg-white', !active);
      btn.classList.toggle('tw-text-gray-700', !active);
      btn.classList.toggle('tw-border-gray-300', !active);
    });
  }

  // The flowbite-datepicker library appends its popup to `container` (document.body by default)
  // synchronously inside the Datepicker constructor — the popup DOM node already exists the
  // instant `new Datepicker(...)` returns, well before the user ever opens it. Flowbite's own
  // wrapper class doesn't expose a `container` option, so instead the popup is physically moved
  // into `.sla-plugin` right here — keeping it inside the plugin's scoped Tailwind/Flowbite CSS
  // (compiled by the same build as everything else in this plugin) instead of rendering
  // unstyled outside the wrapper (CLAUDE.md theme-isolation rule 4).
  function initDatepickers() {
    var scope = document.querySelector('.sla-plugin');
    if (!scope || !window.Datepicker) { return; }

    document.querySelectorAll('[data-sla-datepicker]').forEach(function (el) {
      if (el.slaDatepicker) { return; }

      var instance = new window.Datepicker(el, { autohide: true, format: 'yyyy-mm-dd' });
      el.slaDatepicker = instance;

      var popupEl = instance.getDatepickerInstance && instance.getDatepickerInstance().element;
      if (popupEl && !scope.contains(popupEl)) {
        scope.appendChild(popupEl);
      }
    });
  }

  function bindOnce() {
    if (state.bound) { return; }
    state.bound = true;

    jQuery(document).on('change', '#sla-filter-date-preset', toggleCustomRange);
    jQuery(document).on('click', '[data-sla-preset-btn]', function (e) {
      e.preventDefault();
      selectDatePreset(this);
    });
    jQuery(document).on('change', '[data-sla-auto-apply]', submitImmediately);
    jQuery(document).on('change', '[data-sla-auto-apply-debounced]', submitDebounced);
  }

  function init() {
    if (!byId('sla-filter-date-preset')) { return; }
    initChips();
    initSingleSelects();
    initDatepickers();
    toggleCustomRange();
    bindOnce();
  }

  window.slaDashboardFilters = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
