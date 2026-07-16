/* SLA dashboard filter bar behaviour (Step 6.1). Plain GET filter form — this file only handles
 * cosmetics (Tom Select chip/single-select rendering, toggling the custom date-range fields, and
 * the Datepicker) on top of a form that already works with plain <select>/<input> elements with
 * no JS at all. Idempotent init(), delegated handlers, matching sla_policy_form.js's shape. */
(function () {
  'use strict';

  var state = { bound: false };

  function byId(id) { return document.getElementById(id); }

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
