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

  // #ffffff/#fff or rgb(a)(...) -> the same color at a lower alpha, for dimming a non-highlighted
  // series rather than hiding it. Unrecognized formats pass through unchanged (safe no-op) rather
  // than throwing, since the server payload controls the actual color values, not this file.
  var DIMMED_ALPHA = 0.15;

  function fadeColor(color, alpha) {
    if (typeof color !== 'string') { return color; }
    var hex = color.trim().match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
    if (hex) {
      var digits = hex[1];
      if (digits.length === 3) { digits = digits[0] + digits[0] + digits[1] + digits[1] + digits[2] + digits[2]; }
      var value = parseInt(digits, 16);
      return 'rgba(' + [(value >> 16) & 255, (value >> 8) & 255, value & 255].join(', ') + ', ' + alpha + ')';
    }
    var rgb = color.trim().match(/^rgba?\(([^)]+)\)$/i);
    if (rgb) {
      var parts = rgb[1].split(',');
      if (parts.length < 3) { return color; }
      return 'rgba(' + parts[0].trim() + ', ' + parts[1].trim() + ', ' + parts[2].trim() + ', ' + alpha + ')';
    }
    return color;
  }

  // Clicking a legend entry highlights that data (dims everything else) instead of Chart.js's
  // default hide-on-click behavior - same convention as the time_analytics plugin's own Stacked
  // chart legend (its taLegendHighlight plugin). Two variants, not one shared implementation,
  // because the two chart shapes highlight different things:
  //   - registerDatasetLegendHighlight: one legend item = one whole DATASET (the priority bar's
  //     met/at_risk/breached/no_sla stacks, the trend chart's Created/Resolved lines). Registered
  //     once per canvas id since each needs its own beforeDraw scoped to that chart only.
  //   - registerDonutLegendHighlight: one legend item = one or more DATA-POINT indices within the
  //     donut's single dataset ("met" highlights both its on-track and at-risk arcs together).
  function registerDatasetLegendHighlight(canvasId) {
    var pluginId = 'slaDatasetLegendHighlight_' + canvasId;
    if (Chart.plugins.getAll().some(function (p) { return p.id === pluginId; })) { return; }

    Chart.plugins.register({
      id: pluginId,
      beforeDraw: function (chart) {
        if (chart.canvas.id !== canvasId) { return; }

        var state = chart.$slaLegendHighlight;
        if (!state || state.highlighted === null) { return; }

        chart.data.datasets.forEach(function (dataset, index) {
          var base = state.baseColors[index];
          if (!base) { return; }
          var color = index === state.highlighted ? base : fadeColor(base, DIMMED_ALPHA);
          var meta = chart.getDatasetMeta(index);

          // Line charts have a connecting stroke of their own (meta.dataset), separate from each
          // point - bar/doughnut datasets don't set this, so the guard is a no-op for them.
          if (meta.dataset && meta.dataset._model) { meta.dataset._model.borderColor = color; }
          (meta.data || []).forEach(function (point) {
            if (point._model) {
              point._model.backgroundColor = color;
              if (point._model.borderColor !== undefined) { point._model.borderColor = color; }
            }
          });
        });
      }
    });
  }

  // #rgb / #rrggbb -> a text colour that stays legible on it. Needed because the priority chart
  // draws each segment's value INSIDE the segment, and the palette spans a dark red and a very
  // light gray (no_sla) — a hard-coded white label is invisible on the latter.
  function readableTextOn(color) {
    var hex = typeof color === 'string' && color.trim().match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
    if (!hex) { return '#ffffff'; }

    var digits = hex[1];
    if (digits.length === 3) { digits = digits[0] + digits[0] + digits[1] + digits[1] + digits[2] + digits[2]; }
    var value = parseInt(digits, 16);
    var r = (value >> 16) & 255, g = (value >> 8) & 255, b = value & 255;
    // Perceived brightness (ITU-R BT.601), the same weighting Chart.js's own colour helpers use.
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6 ? '#374151' /* gray-700 */ : '#ffffff';
  }

  // Rounded bar ends for the priority chart. Chart.js 2.9 has no borderRadius option (that arrived
  // in v3), so each bar element's own `draw` is shadowed with this one — an instance property, so
  // Chart.elements.Rectangle.prototype is left alone and no other chart on the page is affected.
  //
  // Only the OUTER ends of a stacked row are rounded: the leftmost non-zero segment rounds its left
  // end and the rightmost rounds its right, so the row reads as one pill rather than as a string of
  // separate lozenges with notches between them. Which segment is which is worked out per row in
  // registerPriorityRoundedBars below and left on the element as $slaRound.
  function drawRoundedBar() {
    var vm = this._view;
    var ctx = this._chart.ctx;
    var left, right, top, bottom, half;

    if (vm.width !== undefined) { // vertical bar
      half = Math.abs(vm.width) / 2;
      left = vm.x - half;
      right = vm.x + half;
      top = Math.min(vm.y, vm.base);
      bottom = Math.max(vm.y, vm.base);
    } else { // horizontalBar: base is the left edge, x the right
      half = Math.abs(vm.height) / 2;
      left = Math.min(vm.x, vm.base);
      right = Math.max(vm.x, vm.base);
      top = vm.y - half;
      bottom = vm.y + half;
    }

    var width = right - left, height = bottom - top;
    if (width <= 0 || height <= 0) { return; }

    var round = this.$slaRound || {};
    // Fully rounded ends (radius = half the bar's thickness), clamped so a narrow segment can never
    // ask for a radius wider than itself — arcTo renders unpredictably when it does.
    var span = (round.left && round.right) ? width / 2 : width;
    var radius = Math.min(height / 2, span);
    var rl = round.left ? radius : 0;
    var rr = round.right ? radius : 0;

    ctx.save();
    ctx.beginPath();
    ctx.moveTo(left + rl, top);
    ctx.lineTo(right - rr, top);
    if (rr) { ctx.arcTo(right, top, right, top + rr, rr); } else { ctx.lineTo(right, top); }
    ctx.lineTo(right, bottom - rr);
    if (rr) { ctx.arcTo(right, bottom, right - rr, bottom, rr); } else { ctx.lineTo(right, bottom); }
    ctx.lineTo(left + rl, bottom);
    if (rl) { ctx.arcTo(left, bottom, left, bottom - rl, rl); } else { ctx.lineTo(left, bottom); }
    ctx.lineTo(left, top + rl);
    if (rl) { ctx.arcTo(left, top, left + rl, top, rl); } else { ctx.lineTo(left, top); }
    ctx.closePath();
    ctx.fillStyle = vm.backgroundColor;
    ctx.fill();
    ctx.restore();
  }

  function registerPriorityRoundedBars() {
    if (Chart.plugins.getAll().some(function (p) { return p.id === 'slaPriorityRoundedBars'; })) { return; }

    Chart.plugins.register({
      id: 'slaPriorityRoundedBars',
      // afterUpdate, not afterInit: Chart.js rebuilds the element list on every update (a legend
      // highlight, a resize), and a `draw` assigned only once would be dropped with the old elements.
      afterUpdate: function (chart) {
        if (chart.canvas.id !== 'sla-priority-chart') { return; }

        var datasets = chart.data.datasets;
        var rowCount = (datasets[0] && datasets[0].data.length) || 0;

        for (var row = 0; row < rowCount; row++) {
          var first = -1, last = -1;
          datasets.forEach(function (dataset, index) {
            if (chart.getDatasetMeta(index).hidden) { return; }
            if ((dataset.data[row] || 0) > 0) {
              if (first < 0) { first = index; }
              last = index;
            }
          });

          datasets.forEach(function (dataset, index) {
            var element = (chart.getDatasetMeta(index).data || [])[row];
            if (!element) { return; }
            element.draw = drawRoundedBar;
            element.$slaRound = { left: index === first, right: index === last };
          });
        }
      }
    });
  }

  function registerDonutLegendHighlight() {
    if (Chart.plugins.getAll().some(function (p) { return p.id === 'slaDonutLegendHighlight'; })) { return; }

    Chart.plugins.register({
      id: 'slaDonutLegendHighlight',
      beforeDraw: function (chart) {
        if (chart.canvas.id !== 'sla-donut-chart') { return; }

        var state = chart.$slaLegendHighlight;
        if (!state || !state.highlightedIndices) { return; }

        var meta = chart.getDatasetMeta(0);
        (meta.data || []).forEach(function (arc, index) {
          var base = state.baseColors[index];
          if (!base || !arc._model) { return; }
          var highlighted = state.highlightedIndices.indexOf(index) !== -1;
          arc._model.backgroundColor = highlighted ? base : fadeColor(base, DIMMED_ALPHA);
        });
      }
    });
  }

  // Delegated click handling for every ERB-rendered legend row (donut + priority chart - the
  // trend chart uses Chart.js's own native, already-clickable legend via legend.onClick instead,
  // see initTrend). Static markup rendered once per page load, so binding directly rather than
  // through a document-level delegate is enough - matches this file's existing init() convention.
  function bindLegendClicks() {
    document.querySelectorAll('[data-sla-legend-target]').forEach(function (el) {
      if (el.slaLegendBound) { return; }
      el.slaLegendBound = true;

      el.addEventListener('click', function () {
        var canvas = byId(el.getAttribute('data-sla-legend-target'));
        var chart = canvas && canvas.slaChartInstance;
        var state = chart && chart.$slaLegendHighlight;
        if (!state) { return; }

        if (el.hasAttribute('data-sla-legend-indices')) {
          var indices = el.getAttribute('data-sla-legend-indices').split(',').map(Number);
          var same = arraysEqual(state.highlightedIndices, indices);
          state.highlightedIndices = same ? null : indices;
        } else if (el.hasAttribute('data-sla-legend-dataset')) {
          var index = Number(el.getAttribute('data-sla-legend-dataset'));
          state.highlighted = state.highlighted === index ? null : index;
        } else {
          return;
        }
        chart.update();
        syncLegendActive(canvas.id, state);
      });
    });
  }

  // Mark which legend entry is driving the highlight. Without this the chart dimmed but the legend
  // looked untouched, so the highlight appeared to come from nowhere — the whole point of the
  // active pill (see partials/_chart_legend.css).
  //
  // The whole GROUP is re-synced from the chart's state rather than just toggling the row that was
  // clicked: highlighting is single-select, so activating one entry has to clear whichever other
  // one was active, and reading back from the state means the class can never disagree with what
  // the chart is actually drawing.
  function syncLegendActive(canvasId, state) {
    var selector = '[data-sla-legend-target="' + canvasId + '"]';
    document.querySelectorAll(selector).forEach(function (el) {
      var active;
      if (el.hasAttribute('data-sla-legend-indices')) {
        var indices = el.getAttribute('data-sla-legend-indices').split(',').map(Number);
        active = arraysEqual(state.highlightedIndices, indices);
      } else {
        active = state.highlighted === Number(el.getAttribute('data-sla-legend-dataset'));
      }
      el.classList.toggle('is-active', active);
    });
  }

  function arraysEqual(a, b) {
    if (!Array.isArray(a) || !Array.isArray(b)) { return false; }
    return a.length === b.length && a.every(function (v, i) { return v === b[i]; });
  }

  function initDonut() {
    var canvas = byId('sla-donut-chart');
    if (!canvas || canvas.slaChartInitialized || !window.Chart) { return; }
    canvas.slaChartInitialized = true;
    registerDonutLegendHighlight();

    var payload = readPayload(canvas);
    var chart = new Chart(canvas.getContext('2d'), {
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

    canvas.slaChartInstance = chart;
    chart.$slaLegendHighlight = { highlightedIndices: null, baseColors: payload.colors.slice() };
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

        // Pass 1 — per-segment values, centered in each segment. The colour is chosen per segment
        // rather than pinned to white: No SLA is a very light gray in this palette, and white-on-
        // gray-300 was unreadable for what is usually the biggest segment on the chart.
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
            ctx.fillStyle = readableTextOn(bar._model.backgroundColor);
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
    registerPriorityRoundedBars();
    registerDatasetLegendHighlight('sla-priority-chart');

    var payload = readPayload(canvas);
    // Cap bar height so a single/few priorities render as slim bars (reference design) instead of
    // stretching to fill the whole card.
    payload.datasets.forEach(function (dataset) { dataset.maxBarThickness = 26; });
    var chart = new Chart(canvas.getContext('2d'), {
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
        // Chart.js's horizontalBar type defaults to tooltips.mode 'index', which lists EVERY
        // dataset for the hovered row (all four SLA states at once). Forcing nearest+intersect
        // reports only the segment actually under the cursor, matching how the donut's tooltip
        // behaves — hover a color, get that color's value.
        tooltips: {
          mode: 'nearest',
          intersect: true,
          callbacks: {
            label: function (item, data) {
              var dataset = data.datasets[item.datasetIndex];
              return dataset.label + ': ' + dataset.data[item.index];
            }
          }
        }
      }
    });

    canvas.slaChartInstance = chart;
    chart.$slaLegendHighlight = {
      highlighted: null,
      baseColors: payload.datasets.map(function (dataset) { return dataset.backgroundColor; })
    };
  }

  // Trend chart (Created vs Resolved). Colors are hand-picked per dataset in the ERB payload (red
  // Created / green Resolved — reusing the plugin's breached/met palette), so each line's meaning
  // reads at a glance and the base colors are known up front. Points are drawn large with a white
  // ring so every data point is clearly visible (per the reference design).
  //
  // Chart.js's own native legend (display: true + legend.onClick) turned out unreliable for click
  // hit-testing in this card's layout - clicks landed on visibly-rendered legend items but never
  // reached onClick. Rather than chase that further, this uses the exact same ERB-legend +
  // bindLegendClicks() pattern the donut/priority charts already use reliably (display: false
  // here), for one consistent, proven mechanism across all three charts.
  function initTrend() {
    var canvas = byId('sla-trend-chart');
    if (!canvas || canvas.slaChartInitialized || !window.Chart) { return; }
    canvas.slaChartInitialized = true;
    registerDatasetLegendHighlight('sla-trend-chart');

    var payload = readPayload(canvas);
    var chart = new Chart(canvas.getContext('2d'), {
      type: 'line',
      data: { labels: payload.labels, datasets: payload.datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        legend: { display: false }, // ERB legend below the chart drives clicks instead
        // Bigger points (radius 5, white 2px ring) so each Created/Resolved data point stands out.
        elements: {
          line: { tension: 0.25, fill: false, borderWidth: 3 },
          point: { radius: 5, hoverRadius: 7, borderWidth: 2, borderColor: '#ffffff' }
        },
        scales: {
          xAxes: [{ gridLines: { display: false, drawBorder: false } }],
          yAxes: [{ ticks: { beginAtZero: true, precision: 0 }, gridLines: { drawBorder: false } }]
        }
      }
    });

    canvas.slaChartInstance = chart;
    // Base colors come straight from the payload now (fixed per dataset) — the "base" the highlight
    // plugin fades away from, and what populateLegendSwatches paints the ERB legend's dots with.
    var baseColors = payload.datasets.map(function (dataset) { return dataset.borderColor; });
    chart.$slaLegendHighlight = { highlighted: null, baseColors: baseColors };
    populateLegendSwatches('sla-trend-chart-legend', baseColors);
  }

  function populateLegendSwatches(legendId, colors) {
    var legend = byId(legendId);
    if (!legend) { return; }
    legend.querySelectorAll('[data-sla-legend-dataset]').forEach(function (item) {
      var index = Number(item.getAttribute('data-sla-legend-dataset'));
      var swatch = item.querySelector('.sla-legend-swatch');
      if (swatch && colors[index]) { swatch.style.backgroundColor = colors[index]; }
    });
  }

  function init() {
    if (!byId('sla-donut-chart') && !byId('sla-priority-chart') && !byId('sla-trend-chart')) { return; }
    initDonut();
    initPriorityChart();
    initTrend();
    bindLegendClicks();
  }

  window.slaDashboardCharts = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
