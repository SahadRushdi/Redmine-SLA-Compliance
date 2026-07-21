/* SLA dashboard filter bar behaviour (Step 6.1). Plain GET filter form — this file only handles
 * cosmetics (Tom Select chip/single-select rendering, toggling the custom date-range fields, and
 * the Datepicker) on top of a form that already works with plain <select>/<input> elements with
 * no JS at all. Idempotent init(), delegated handlers, matching sla_policy_form.js's shape. */
(function () {
  'use strict';

  var AUTO_APPLY_DEBOUNCE_MS = 700;
  var state = { bound: false, debounceTimer: null, rangeOutsideCloseBound: false };

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

    var custom = preset.value === 'custom';
    field.classList.toggle('hidden', !custom);

    // An open popup lives under `.sla-plugin`, not under #sla-custom-range (initDateRangePicker
    // re-homes it), so hiding the wrapper does NOT hide the calendar with it — it would be left
    // floating over the dashboard, anchored to an input that is no longer there. Close it here.
    if (!custom) { hideRangePickers(); }
  }

  function hideRangePickers() {
    ['sla-filter-from', 'sla-filter-to'].forEach(function (id) {
      var input = byId(id);
      if (input && input.datepicker && input.datepicker.hide) { input.datepicker.hide(); }
    });
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

  // Granularity pills (Daily/Weekly/Monthly) for the trend chart. Same segmented-pill-over-a-
  // hidden-<select> pattern as the Date Range pills above, but the pills live in
  // _trend_chart.html.erb - outside #sla-filter-form's own DOM subtree (that partial renders as a
  // sibling of _filter_bar.html.erb under sla_dashboard/index.html.erb). The hidden <select>
  // carries `form="sla-filter-form"` so it's still submitted as part of that form (HTML5 form
  // association), but submitting here targets #sla-filter-form by id directly rather than
  // `closest('form')`, which would find nothing from this DOM position.
  function selectGranularity(btn) {
    var select = byId('sla-filter-granularity');
    var form = byId('sla-filter-form');
    if (!select || !form) { return; }

    select.value = btn.getAttribute('data-sla-granularity-btn');
    markActiveGranularityButton(btn);
    (form.requestSubmit ? form.requestSubmit() : form.submit());
  }

  function markActiveGranularityButton(activeBtn) {
    document.querySelectorAll('[data-sla-granularity-btn]').forEach(function (btn) {
      var active = btn === activeBtn;
      btn.classList.toggle('tw-bg-primary-600', active);
      btn.classList.toggle('tw-text-white', active);
      btn.classList.toggle('tw-border-primary-600', active);
      btn.classList.toggle('tw-bg-white', !active);
      btn.classList.toggle('tw-text-gray-700', !active);
      btn.classList.toggle('tw-border-gray-300', !active);
    });
  }

  // Custom Range: ONE linked flowbite DateRangePicker across the From/To inputs (matching the
  // My Time page), not two independent Datepickers. The link is what makes the two popups agree —
  // it tints the days between the two dates (.range) and stops To being set before From. The
  // library discovers its two inputs itself via `element.querySelectorAll('input')` in DOM order,
  // so `#sla-custom-range` (the wrapper holding both) IS the picker element.
  //
  // Each popup is appended to `config.container` (document.body by default) synchronously inside
  // the constructor — the popup DOM node exists the instant `new Datepicker(...)` returns, well
  // before the user ever opens it. Every rule in this plugin's stylesheet is scoped under
  // `.sla-plugin` (postcss.config.js), and every Tailwind class in the library's own popup
  // template is unprefixed, so a popup left in document.body is matched by NOTHING: not
  // `.datepicker { display: none }`, not `.datepicker-dropdown { position: absolute }`, not the
  // `tw-`-prefixed utilities. It renders as an unstyled, permanently-visible block at the end of
  // <body> and the input looks dead on click.
  //
  // So each popup is re-homed into `.sla-plugin`. Two things are required, not one:
  //   1. The popup is `datepicker.picker.element`. `datepicker.element` is the INPUT — reading
  //      that instead makes the move a silent no-op (the input is already inside the scope).
  //   2. `config.container` must be updated to match. The library reads it lazily in `place()`
  //      (relative-to-container coordinates) and `detach()` (removeChild) — leaving it pointing
  //      at document.body while the popup lives elsewhere positions it against the wrong box.
  //      The library takes a `container` option for exactly this, but Flowbite's wrapper class
  //      whitelists the options it forwards and drops it, hence assigning after construction.
  // `.sla-plugin` is `position: relative` (tailwind.input.css) so it is the popup's offsetParent,
  // which is what makes those container-relative coordinates land correctly.
  //
  // `todayHighlight` goes through each inner picker's own setOptions for the same reason: it's
  // not on Flowbite's forwarded-options whitelist either. Same approach the time_analytics
  // plugin takes with its own range picker.
  function initDateRangePicker() {
    var scope = document.querySelector('.sla-plugin');
    var rangeEl = byId('sla-custom-range');
    if (!scope || !rangeEl || rangeEl.slaRangePicker || !window.Datepicker) { return; }

    var instance = new window.Datepicker(rangeEl, {
      rangePicker: true,
      autohide: true,
      format: 'mm/dd/yyyy' // matches the My Time page's picker (Time Analytics plugin)
    });
    rangeEl.slaRangePicker = instance;

    var inner = instance.getDatepickerInstance && instance.getDatepickerInstance();
    var datepickers = (inner && inner.datepickers) || [];
    datepickers.forEach(function (dp) {
      // showOnFocus/showOnClick: false hands ALL opening/closing over to bindManualRangeToggle
      // below, instead of Flowbite's own triggers. This isn't a style preference - Flowbite's
      // built-in autohide (onClickOutside in flowbite.min.js) starts with
      // `if (element !== document.activeElement) return;`, and by the time that listener runs for
      // the FROM picker, clicking TO has already moved focus there, so the guard is always true
      // and hide() never gets called. Both popups stay open and overlap (visibly, since they're
      // both `position: absolute` and anchored to adjacent inputs) - the exact same bug the
      // time_analytics plugin's own range picker (My Time / My Team pages) hit and works around
      // with this identical manual-toggle approach, not a new pattern invented here.
      dp.setOptions({ todayHighlight: true, showOnFocus: false, showOnClick: false, autohide: true });
      if (dp.picker && dp.picker.element) {
        dp.config.container = scope;
        scope.appendChild(dp.picker.element);
      }
    });

    // Why this can't ride on the generic [data-sla-auto-apply-debounced] `change` binding, and
    // why it can't be delegated off `document`:
    //   - The library sets `inputField.value` programmatically, and assigning .value NEVER fires
    //     a native `change`. It signals a pick with its own `changeDate` CustomEvent instead
    //     (`datepicker.element.dispatchEvent(new CustomEvent('changeDate', ...))`). That is why
    //     choosing dates previously left the dashboard sitting there un-refreshed.
    //   - That CustomEvent is constructed WITHOUT `bubbles: true`, so it never reaches a
    //     delegated jQuery handler on document. It has to be bound on the input itself.
    // `change` is still bound alongside it so typing a date by hand and tabbing out also applies.
    ['sla-filter-from', 'sla-filter-to'].forEach(function (id) {
      var input = byId(id);
      if (!input) { return; }
      input.addEventListener('changeDate', submitDateRangeDebounced);
      input.addEventListener('change', submitDateRangeDebounced);
    });

    bindManualRangeToggle();
  }

  // Full manual show/hide control for the two linked pickers, replacing Flowbite's own (broken,
  // see above) showOnFocus/showOnClick/autohide triggers - same working pattern as the
  // time_analytics plugin's My Time/My Team range pickers, ported here rather than duplicated
  // per-view: one click handler per input (toggle this picker, always closing the sibling's
  // first), Escape to close, and a document-level outside-click that closes both.
  function bindManualRangeToggle() {
    var from = byId('sla-filter-from');
    var to = byId('sla-filter-to');

    function bindToggle(input, sibling) {
      if (!input || input.dataset.slaRangeToggleBound === '1') { return; }
      input.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        if (!input.datepicker) { return; }
        if (sibling && sibling.datepicker && sibling.datepicker.active) { sibling.datepicker.hide(); }
        if (input.datepicker.active) { input.datepicker.hide(); } else { input.datepicker.show(); }
      });
      input.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && input.datepicker && input.datepicker.hide) {
          input.datepicker.hide();
          input.blur();
        }
      });
      input.dataset.slaRangeToggleBound = '1';
    }
    bindToggle(from, to);
    bindToggle(to, from);

    // Neither input should open its picker just because the page loaded with focus already on
    // it (autofocus, browser form-restore, tabbing through on page load before the user has
    // actually clicked either field) - showOnFocus is already off, but this is a defensive
    // belt-and-braces pass matching the time_analytics plugin's own suppressAutoOpen, run once
    // synchronously and once after a short delay to also catch anything a slower-to-init browser
    // extension/autofill triggers just after load.
    function suppressAutoOpen() {
      [from, to].forEach(function (input) {
        if (input && document.activeElement === input) { input.blur(); }
      });
      hideRangePickers();
    }
    setTimeout(suppressAutoOpen, 0);
    setTimeout(suppressAutoOpen, 120);

    if (state.rangeOutsideCloseBound) { return; }
    state.rangeOutsideCloseBound = true;
    document.addEventListener('mousedown', function (e) {
      var target = e.target;
      var rangeEl = byId('sla-custom-range');
      var insideRangeUi = (rangeEl && rangeEl.contains(target)) || !!(target.closest && target.closest('.datepicker'));
      if (insideRangeUi) { return; }
      hideRangePickers();
    });
  }

  // Only submit once BOTH ends of the range are filled — picking From always fires changeDate
  // before the user has had a chance to touch To, and submitting there would navigate away
  // mid-selection. Same completeness guard the time_analytics range picker uses, over this
  // plugin's existing shared debounce.
  function submitDateRangeDebounced() {
    var from = byId('sla-filter-from');
    var to = byId('sla-filter-to');
    if (!from || !to || !from.value || !to.value) { return; }
    submitDebounced.call(from);
  }

  function bindOnce() {
    if (state.bound) { return; }
    state.bound = true;

    jQuery(document).on('change', '#sla-filter-date-preset', toggleCustomRange);
    jQuery(document).on('click', '[data-sla-preset-btn]', function (e) {
      e.preventDefault();
      selectDatePreset(this);
    });
    jQuery(document).on('click', '[data-sla-granularity-btn]', function (e) {
      e.preventDefault();
      selectGranularity(this);
    });
    jQuery(document).on('change', '[data-sla-auto-apply]', submitImmediately);
    jQuery(document).on('change', '[data-sla-auto-apply-debounced]', submitDebounced);
  }

  function init() {
    if (!byId('sla-filter-date-preset')) { return; }
    initChips();
    initSingleSelects();
    initDateRangePicker();
    toggleCustomRange();
    bindOnce();
  }

  window.slaDashboardFilters = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
