/* Near-real-time dashboard refresh without a server-side scheduler. A refresh is requested only
 * while this dashboard tab is visible, so closed/background dashboards create no database load.
 * The server continues to answer from indexed sla_results projections; it does not reconstruct
 * issue journals on these reads. */
(function () {
  'use strict';

  var REFRESH_MILLISECONDS = 15000;
  var timer;

  function schedule() {
    window.clearTimeout(timer);
    if (document.hidden) { return; }
    timer = window.setTimeout(function () {
      if (!document.hidden) { window.location.reload(); }
    }, REFRESH_MILLISECONDS);
  }

  function init() {
    if (!document.querySelector('.sla-plugin [data-sla-tab-panel="open"]')) { return; }
    document.addEventListener('visibilitychange', schedule);
    schedule();
  }

  document.addEventListener('DOMContentLoaded', init);
})();
