/* Keeps cache-backed SLA projections visibly current without calculating journals on page load.
 * A normal navigation to the same URL re-runs the indexed effective-state queries, refreshes
 * charts and rows, and projects breached duration from breach_at. Refresh is deferred while the
 * user is interacting, the detail modal is open, or this browser tab is hidden. */
(function () {
  'use strict';

  function init() {
    var dashboard = document.querySelector('[data-sla-live-dashboard]');
    if (!dashboard || dashboard.slaLiveInitialized) { return; }
    dashboard.slaLiveInitialized = true;

    var interval = Number(dashboard.getAttribute('data-refresh-interval')) || 30000;
    var lastInteraction = Date.now();

    ['input', 'change', 'click', 'keydown'].forEach(function (eventName) {
      dashboard.addEventListener(eventName, function () { lastInteraction = Date.now(); });
    });

    function busy() {
      var modal = document.getElementById('sla-detail-modal');
      var focused = document.activeElement && dashboard.contains(document.activeElement) &&
                    /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
      return document.hidden || focused || (modal && !modal.classList.contains('hidden')) ||
             Date.now() - lastInteraction < 5000;
    }

    function refresh() {
      if (busy()) {
        window.setTimeout(refresh, 5000);
        return;
      }
      window.location.reload();
    }

    window.setTimeout(refresh, interval);
  }

  document.addEventListener('DOMContentLoaded', init);
})();
