/* SLA dashboard tab switcher (Open Tickets / SLA Trend). Both panels are rendered server-side and
 * present in the DOM; this only toggles the LITERAL `hidden` class and the active-tab pill, so
 * switching never reloads. The active tab is remembered in sessionStorage so a date-range change
 * (which submits #sla-filter-form and reloads the page from the SLA Trend tab) returns on the same
 * tab. Same IIFE / idempotent-init / DOMContentLoaded convention as the other dashboard scripts;
 * plain ES5 for parity. Loaded BEFORE sla_dashboard_charts.js so on first load the correct panel is
 * already visible when the charts initialize (a Chart.js line chart built inside a display:none
 * panel renders at 0×0); switching tabs later resizes any chart in the newly-shown panel to cover
 * the case where it was initialized while hidden. */
(function () {
  'use strict';

  var STORAGE_KEY = 'slaActiveTab';

  var ACTIVE_CLASSES = ['tw-bg-white', 'tw-text-gray-900', 'tw-shadow-sm'];
  var INACTIVE_CLASSES = ['tw-bg-transparent', 'hover:tw-bg-transparent', 'tw-text-gray-500',
                          'hover:tw-text-gray-700', 'tw-shadow-none'];

  function panels() {
    return Array.prototype.slice.call(document.querySelectorAll('[data-sla-tab-panel]'));
  }

  function buttons() {
    return Array.prototype.slice.call(document.querySelectorAll('[data-sla-tab]'));
  }

  // Chart.js instances built inside a hidden panel come up at 0×0; resize once the panel is shown.
  function resizeChartsIn(panel) {
    panel.querySelectorAll('canvas').forEach(function (canvas) {
      if (canvas.slaChartInstance && typeof canvas.slaChartInstance.resize === 'function') {
        canvas.slaChartInstance.resize();
      }
    });
  }

  function activate(key, persist) {
    panels().forEach(function (panel) {
      var match = panel.getAttribute('data-sla-tab-panel') === key;
      panel.classList.toggle('hidden', !match);
      if (match) { resizeChartsIn(panel); }
    });

    buttons().forEach(function (btn) {
      var active = btn.getAttribute('data-sla-tab') === key;
      btn.setAttribute('aria-selected', active ? 'true' : 'false');
      ACTIVE_CLASSES.forEach(function (c) { btn.classList.toggle(c, active); });
      INACTIVE_CLASSES.forEach(function (c) { btn.classList.toggle(c, !active); });
    });

    if (persist) {
      try { sessionStorage.setItem(STORAGE_KEY, key); } catch (e) { /* private mode */ }
    }
  }

  function init() {
    var nav = document.getElementById('sla-dashboard-tabs');
    if (!nav || nav.slaTabsInitialized) { return; }
    nav.slaTabsInitialized = true;

    var keys = buttons().map(function (b) { return b.getAttribute('data-sla-tab'); });
    var stored;
    try { stored = sessionStorage.getItem(STORAGE_KEY); } catch (e) { stored = null; }
    var initial = (stored && keys.indexOf(stored) !== -1) ? stored : (nav.getAttribute('data-sla-default-tab') || keys[0]);

    activate(initial, false);

    buttons().forEach(function (btn) {
      btn.addEventListener('click', function () { activate(btn.getAttribute('data-sla-tab'), true); });
    });
  }

  window.slaDashboardTabs = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
