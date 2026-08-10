/* Shared client-side table-sort primitives: the sort-direction icons, how a cell yields a sortable
 * value, and how two of those values compare.
 *
 * Extracted from sla_dashboard_detail_table.js when the admin module's lookup tables needed the
 * same behaviour. Both files now read from here, so the two tables cannot drift into sorting the
 * same-looking column by different rules or showing different arrows for the same state — which is
 * the whole reason this is a module and not a copy-paste.
 *
 * Loaded from sla_compliance/_assets.html.erb, i.e. on every page of the plugin. Consumers must
 * read `window.slaTableSort` INSIDE a function, never at parse time: everything here goes into
 * <head> without `defer`, so a consumer that captured `.ICONS` into a top-level var would depend on
 * script order, which the two including views control separately.
 */
(function () {
  'use strict';

  window.slaTableSort = {
    // Grey arrows only (no brand colour, per Global Rule 7): both chevrons on an unsorted column,
    // a single up/down arrow for the active sort direction. Colour comes from the containing
    // element's `currentColor`, so a caller decides the shade with a text utility.
    ICONS: {
      neutral: '<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">' +
               '<path d="M8 10l4-4 4 4" stroke-linecap="round" stroke-linejoin="round"/>' +
               '<path d="M8 14l4 4 4-4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      asc: '<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">' +
           '<path d="M7 14l5-5 5 5" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      desc: '<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">' +
            '<path d="M7 10l5 5 5-5" stroke-linecap="round" stroke-linejoin="round"/></svg>'
    },

    // A cell sorts by its `data-sla-sort-value` when it has one, else by its text. The attribute is
    // what lets a column sort by something other than what it displays — a duration rendered "2d"
    // sorting by its seconds, a status sorting by its position rather than its name.
    cellValue: function (row, index) {
      var cell = row.children[index];
      if (!cell) { return ''; }
      var explicit = cell.getAttribute('data-sla-sort-value');
      return explicit !== null ? explicit : (cell.textContent || '').trim();
    },

    // Blanks always sort last, regardless of direction, for both numeric and text columns. A row
    // with no value is neither the smallest nor the largest, and letting it swap ends as the arrow
    // flips reads as a bug — this is what keeps a Best Effort target option (no duration) pinned to
    // the bottom either way.
    compare: function (a, b, type, dir) {
      var mul = dir === 'asc' ? 1 : -1;
      if (type === 'number') {
        var na = (a === '' || a == null) ? null : parseFloat(a);
        var nb = (b === '' || b == null) ? null : parseFloat(b);
        if (na === null && nb === null) { return 0; }
        if (na === null) { return 1; }
        if (nb === null) { return -1; }
        if (na === nb) { return 0; }
        return (na < nb ? -1 : 1) * mul;
      }
      var sa = (a || '').toLowerCase(), sb = (b || '').toLowerCase();
      if (sa === '' && sb === '') { return 0; }
      if (sa === '') { return 1; }
      if (sb === '') { return -1; }
      return sa.localeCompare(sb) * mul;
    }
  };
})();
