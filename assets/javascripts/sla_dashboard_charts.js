/* SLA dashboard charts (Step 6.3). All chart *data* is computed server-side from the sla_results
 * cache (Sla::ResultSummary / Sla::PriorityBreakdown) and embedded as JSON in each canvas's
 * data-chart attribute - this file only builds Chart.js instances from that JSON. Same IIFE /
 * idempotent-init / DOMContentLoaded convention as sla_dashboard_filters.js. Chart.js v2 API
 * (matches the chart.js version already vendored by every other plugin in this Redmine install -
 * see redmine_time_analytics / redmine_stats). */
(function () {
  'use strict';

  function byId(id) { return document.getElementById(id); }

  function readPayload(canvas) {
    return JSON.parse(canvas.getAttribute('data-chart'));
  }

  function formatPercent(value, total) {
    return total > 0 ? ((value / total) * 100).toFixed(1) : '0.0';
  }

  function initDonut() {
    var canvas = byId('sla-donut-chart');
    if (!canvas || canvas.slaChartInitialized || !window.Chart) { return; }
    canvas.slaChartInitialized = true;

    var payload = readPayload(canvas);
    new Chart(canvas.getContext('2d'), {
      type: 'doughnut',
      data: {
        labels: payload.labels,
        datasets: [{
          data: payload.data,
          backgroundColor: payload.colors,
          borderColor: '#ffffff',
          borderWidth: 2
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        cutoutPercentage: 62,
        legend: { display: false }, // one shared legend is rendered above, in ERB
        tooltips: {
          callbacks: {
            label: function (item, data) {
              var label = data.labels[item.index] || '';
              var value = data.datasets[item.datasetIndex].data[item.index];
              return label + ': ' + value + ' (' + formatPercent(value, payload.total) + '%)';
            }
          }
        }
      }
    });
  }

  // Two label passes on the priority chart (scoped to this one chart by id so it never draws on
  // the donut, which shares the same global Chart.js instance):
  //   1. white per-segment value centered inside each stacked segment wide enough to fit (< ~18px
  //      segments are skipped rather than overlapping neighbours illegibly);
  //   2. the per-row TOTAL (sum of every segment) in dark bold just past the right end of each
  //      stack — matching the reference design's 27 / 74 / 111 at the end of each bar.
  function registerPriorityValueLabels() {
    if (Chart.plugins.getAll().some(function (p) { return p.id === 'slaPriorityValueLabels'; })) { return; }

    Chart.plugins.register({
      id: 'slaPriorityValueLabels',
      afterDatasetsDraw: function (chart) {
        if (chart.canvas.id !== 'sla-priority-chart') { return; }

        var ctx = chart.ctx;
        var datasets = chart.data.datasets;
        var rowCount = (datasets[0] && datasets[0].data.length) || 0;
        var totals = [], rowRight = [], rowY = [];
        for (var i = 0; i < rowCount; i++) { totals[i] = 0; rowRight[i] = 0; rowY[i] = null; }

        ctx.save();

        // Pass 1 — per-segment values, white, centered in each segment.
        ctx.fillStyle = '#ffffff';
        ctx.font = 'bold 12px sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';

        datasets.forEach(function (dataset, datasetIndex) {
          var meta = chart.getDatasetMeta(datasetIndex);
          if (meta.hidden) { return; }

          meta.data.forEach(function (bar, index) {
            var value = dataset.data[index] || 0;
            totals[index] += value;
            if (bar._model.x > rowRight[index]) { rowRight[index] = bar._model.x; }
            rowY[index] = bar._model.y;

            if (!value) { return; }
            var width = bar._model.base - bar._model.x; // horizontalBar: base = left edge, x = right edge
            if (Math.abs(width) < 18) { return; }
            ctx.fillText(String(value), bar._model.x + width / 2, bar._model.y);
          });
        });

        // Pass 2 — per-row totals, dark gray, just past the right end of each stack.
        ctx.fillStyle = '#374151'; // gray-700
        ctx.textAlign = 'left';
        totals.forEach(function (total, index) {
          if (rowY[index] === null) { return; }
          ctx.fillText(String(total), rowRight[index] + 8, rowY[index]);
        });

        ctx.restore();
      }
    });
  }

  function initPriorityChart() {
    var canvas = byId('sla-priority-chart');
    if (!canvas || canvas.slaChartInitialized || !window.Chart) { return; }
    canvas.slaChartInitialized = true;
    registerPriorityValueLabels();

    var payload = readPayload(canvas);
    // Cap bar height so a single/few priorities render as slim bars (reference design) instead of
    // stretching to fill the whole card.
    payload.datasets.forEach(function (dataset) { dataset.maxBarThickness = 26; });
    new Chart(canvas.getContext('2d'), {
      type: 'horizontalBar',
      data: { labels: payload.labels, datasets: payload.datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        legend: { display: false }, // same shared legend as the donut - identical color mapping
        layout: { padding: { right: 40 } }, // room for the per-row total labels drawn past each bar
        // No outer frame/gridlines (reference design): hide the x scale entirely and drop the
        // y-axis border/gridlines, keeping only the priority category labels.
        scales: {
          xAxes: [{ stacked: true, display: false, gridLines: { display: false, drawBorder: false },
                    ticks: { beginAtZero: true, precision: 0, display: false } }],
          yAxes: [{ stacked: true, gridLines: { display: false, drawBorder: false } }]
        },
        tooltips: {
          callbacks: {
            label: function (item, data) {
              var dataset = data.datasets[item.datasetIndex];
              return dataset.label + ': ' + dataset.data[item.index];
            }
          }
        }
      }
    });
  }

  // Trend chart (Created vs Resolved). Unlike the donut/priority charts, Created and Resolved
  // have no fixed semantic meaning (they aren't a state like met/breached), so colors come from
  // chartjs-plugin-colorschemes' Tableau 10 scheme instead of a hand-picked backgroundColor array
  // - the one case CLAUDE.md calls out a Tableau-10 blue "Created" line as intentional chart data
  // encoding, not a UI-chrome collision. The chart keeps its own native legend (display: true)
  // since Created/Resolved aren't part of the donut/priority charts' shared met/breached/at_risk/
  // no_sla legend.
  function initTrend() {
    var canvas = byId('sla-trend-chart');
    if (!canvas || canvas.slaChartInitialized || !window.Chart) { return; }
    canvas.slaChartInitialized = true;

    var payload = readPayload(canvas);
    new Chart(canvas.getContext('2d'), {
      type: 'line',
      data: { labels: payload.labels, datasets: payload.datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { colorschemes: { scheme: 'tableau.Tableau10' } },
        legend: { position: 'top', align: 'end' },
        elements: { line: { tension: 0.25, fill: false }, point: { radius: 2, hoverRadius: 4 } },
        scales: {
          xAxes: [{ gridLines: { display: false, drawBorder: false } }],
          yAxes: [{ ticks: { beginAtZero: true, precision: 0 }, gridLines: { drawBorder: false } }]
        }
      }
    });
  }

  function init() {
    if (!byId('sla-donut-chart') && !byId('sla-priority-chart') && !byId('sla-trend-chart')) { return; }
    initDonut();
    initPriorityChart();
    initTrend();
  }

  window.slaDashboardCharts = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
