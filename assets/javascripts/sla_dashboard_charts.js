/* SLA dashboard charts (Step 6.3). All chart *data* is computed server-side from the sla_results
 * cache (Sla::ResultSummary / Sla::PriorityBreakdown / Sla::TrendSeries) and embedded as JSON in
 * each canvas's data-chart attribute - this file only builds Chart.js instances from that JSON
 * and wires the Daily/Weekly/Monthly toggle (a pure client-side re-render, all three granularities
 * are already in the trend payload). Same IIFE / idempotent-init / DOMContentLoaded convention as
 * sla_dashboard_filters.js. Chart.js v2 API (matches the chart.js version already vendored by
 * every other plugin in this Redmine install - see redmine_time_analytics / redmine_stats). */
(function () {
  'use strict';

  var state = { bound: false, trendChart: null, trendPayload: null };

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

  // Centered white value label inside each stacked-bar segment (matching the reference design) -
  // scoped to this one chart by id so it never draws on the donut/trend charts, which share the
  // same global Chart.js instance. Segments too narrow for their own label (< ~18px) are skipped
  // rather than overlapping neighbours illegibly.
  function registerPriorityValueLabels() {
    if (Chart.plugins.getAll().some(function (p) { return p.id === 'slaPriorityValueLabels'; })) { return; }

    Chart.plugins.register({
      id: 'slaPriorityValueLabels',
      afterDatasetsDraw: function (chart) {
        if (chart.canvas.id !== 'sla-priority-chart') { return; }

        var ctx = chart.ctx;
        ctx.save();
        ctx.fillStyle = '#ffffff';
        ctx.font = 'bold 12px sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';

        chart.data.datasets.forEach(function (dataset, datasetIndex) {
          var meta = chart.getDatasetMeta(datasetIndex);
          if (meta.hidden) { return; }

          meta.data.forEach(function (bar, index) {
            var value = dataset.data[index];
            if (!value) { return; }

            var width = bar._model.base - bar._model.x; // horizontalBar: base = left edge, x = right edge
            if (Math.abs(width) < 18) { return; }

            ctx.fillText(String(value), bar._model.x + width / 2, bar._model.y);
          });
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
    new Chart(canvas.getContext('2d'), {
      type: 'horizontalBar',
      data: { labels: payload.labels, datasets: payload.datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        legend: { display: false }, // same shared legend as the donut - identical color mapping
        scales: {
          xAxes: [{ stacked: true, ticks: { beginAtZero: true, precision: 0 } }],
          yAxes: [{ stacked: true }]
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

  function trendDatasets(payload, granularity) {
    var bucket = payload[granularity];
    return {
      labels: bucket.labels,
      datasets: [
        { label: payload.labelCreated, data: bucket.created, borderColor: payload.colors.created,
          backgroundColor: payload.colors.created, fill: false, tension: 0.2, pointRadius: 2 },
        { label: payload.labelResolved, data: bucket.resolved, borderColor: payload.colors.resolved,
          backgroundColor: payload.colors.resolved, fill: false, tension: 0.2, pointRadius: 2 }
      ]
    };
  }

  function initTrend() {
    var canvas = byId('sla-trend-chart');
    if (!canvas || canvas.slaChartInitialized || !window.Chart) { return; }
    canvas.slaChartInitialized = true;

    state.trendPayload = readPayload(canvas);
    var initial = trendDatasets(state.trendPayload, 'daily');
    state.trendChart = new Chart(canvas.getContext('2d'), {
      type: 'line',
      data: initial,
      options: {
        responsive: true,
        maintainAspectRatio: false,
        legend: { display: false }, // rendered as a small static legend in ERB above the canvas
        scales: {
          xAxes: [{ ticks: { autoSkip: true, maxTicksLimit: 12 } }],
          yAxes: [{ ticks: { beginAtZero: true, precision: 0 } }]
        }
      }
    });
  }

  function setActiveGranularityButton(button) {
    var group = byId('sla-trend-granularity');
    if (!group) { return; }
    Array.prototype.forEach.call(group.querySelectorAll('[data-sla-trend-granularity]'), function (btn) {
      var active = btn === button;
      btn.classList.toggle('tw-bg-primary-600', active);
      btn.classList.toggle('tw-text-white', active);
      btn.classList.toggle('tw-border-primary-600', active);
      btn.classList.toggle('tw-z-10', active);
      btn.classList.toggle('tw-bg-white', !active);
      btn.classList.toggle('tw-text-gray-600', !active);
      btn.classList.toggle('tw-border-gray-300', !active);
    });
  }

  function switchGranularity(button) {
    if (!state.trendChart || !state.trendPayload) { return; }
    var granularity = button.getAttribute('data-sla-trend-granularity');
    var next = trendDatasets(state.trendPayload, granularity);
    state.trendChart.data.labels = next.labels;
    state.trendChart.data.datasets[0].data = next.datasets[0].data;
    state.trendChart.data.datasets[1].data = next.datasets[1].data;
    state.trendChart.update();
    setActiveGranularityButton(button);
  }

  function bindOnce() {
    if (state.bound) { return; }
    state.bound = true;

    jQuery(document).on('click', '[data-sla-trend-granularity]', function () {
      switchGranularity(this);
    });
  }

  function init() {
    if (!byId('sla-donut-chart') && !byId('sla-priority-chart') && !byId('sla-trend-chart')) { return; }
    initDonut();
    initPriorityChart();
    initTrend();
    bindOnce();
  }

  window.slaDashboardCharts = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
