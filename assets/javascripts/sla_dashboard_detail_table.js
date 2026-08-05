/* SLA dashboard ticket-level detail table — client-side search + sorting + pagination (no page
 * reload). The controller renders the full filtered row set (state tab / main filters still
 * resubmit server-side, since they change which rows are in scope); this file searches, sorts and
 * paginates those already-rendered rows in place. Free-text search matches each row's
 * data-sla-search attribute (ticket id, project, tracker, title, status, assignee, result -
 * built server-side in _detail_table.html.erb) and updates on every keystroke. Sort direction is
 * shown by a grey up/down arrow on the active column header (never blue). Same IIFE /
 * idempotent-init / DOMContentLoaded convention as the other dashboard scripts. Plain ES5 for
 * parity with the rest of the plugin's JS. */
(function () {
  'use strict';

  // sessionStorage flag used to re-open the expand modal after a state-pill server reload (see
  // initExpandModal), so filtering from inside the modal doesn't visibly drop the user back to the
  // compact card.
  var MODAL_OPEN_KEY = 'slaDetailModalOpen';

  // Rows per page for the compact in-card table. It is deliberately NOT one of the per-page
  // dropdown options (10/25/50/100) — that dropdown only governs the expanded modal; the compact
  // card always paginates 6-at-a-time so it stays the same height as the donut/priority cards
  // beside it. Opening the modal switches to the dropdown's size; closing it returns to 6.
  var COMPACT_PAGE_SIZE = 6;

  function byId(id) { return document.getElementById(id); }

  // Mirrors Redmine::Pagination::Paginator#linked_pages (lib/redmine/pagination.rb) so this
  // client-side pager windows exactly like Redmine's own server-rendered ones (Spent time, issue
  // list): always first + last + current, plus current ± 2, with the gaps rendered as an ellipsis.
  // Without it a 259-row scope at 6/page emitted all 41 page buttons, which overflowed the card and
  // pushed the whole dashboard into horizontal scroll.
  function linkedPages(current, pages) {
    var wanted = [1, current, pages];
    for (var p = current - 2; p <= current + 2; p++) {
      if (p > 1 && p < pages) { wanted.push(p); }
    }
    return wanted
      .filter(function (page, index) { return page >= 1 && page <= pages && wanted.indexOf(page) === index; })
      .sort(function (a, b) { return a - b; });
  }

  // Inert grey "…" marking a skipped range between two page buttons. Deliberately a <span>, never a
  // <button>, so it can't be mistaken for (or focused as) a page.
  function ellipsisSpacer() {
    var span = document.createElement('span');
    span.className = 'tw-px-2 tw-py-1.5 tw-text-xs tw-text-gray-400 tw-select-none';
    span.textContent = '…';
    return span;
  }

  function Table(root) {
    this.root = root;
    this.tbody = root.querySelector('#sla-detail-table-body');
    this.rows = Array.prototype.slice.call(this.tbody.querySelectorAll('tr[data-sla-row]'));
    this.headers = Array.prototype.slice.call(root.querySelectorAll('thead th[data-sla-sort]'));
    this.pager = root.querySelector('#sla-detail-pagination');
    this.perPage = root.querySelector('[data-sla-perpage]');
    this.searchInput = root.querySelector('#sla-detail-search');
    this.noMatchRow = null;
    this.pageSize = COMPACT_PAGE_SIZE; // compact default; modal open() switches to the dropdown size
    this.page = 1;
    this.sortKey = null;
    this.sortDir = 'asc';
    // Pre-filled from the server (e.g. a bookmarked ?q= link) so the table is already filtered
    // to match the search box on first render, exactly like every other keystroke after that.
    this.searchQuery = this.searchInput ? this.searchInput.value.trim().toLowerCase() : '';
    this.labels = this.pager ? {
      showing: this.pager.getAttribute('data-l-showing') || 'Showing',
      of: this.pager.getAttribute('data-l-of') || 'of',
      prev: this.pager.getAttribute('data-l-prev') || 'Previous',
      next: this.pager.getAttribute('data-l-next') || 'Next'
    } : {};
  }

  // 10 is the default page size for the compact in-card table (the hidden <select> renders
  // pre-selected on 10); the modal's per-page dropdown can raise it and closing the modal resets
  // it back to 10 (see initExpandModal).
  Table.prototype.readPageSize = function () {
    var value = this.perPage ? parseInt(this.perPage.value, 10) : 10;
    return (value && value > 0) ? value : 10;
  };

  Table.prototype.columnIndex = function (key) {
    for (var i = 0; i < this.headers.length; i++) {
      if (this.headers[i].getAttribute('data-sla-sort') === key) { return i; }
    }
    return -1;
  };

  // Matches against the row's pre-built data-sla-search attribute (ticket id, project, tracker,
  // title, status, assignee, result - see _detail_table.html.erb), not just the visible columns,
  // so the free-text box searches every field a user would reasonably expect it to.
  Table.prototype.matchesSearch = function (row) {
    if (!this.searchQuery) { return true; }
    var haystack = row.getAttribute('data-sla-search') || row.textContent || '';
    return haystack.toLowerCase().indexOf(this.searchQuery) !== -1;
  };

  Table.prototype.filteredRows = function () {
    var self = this;
    return this.rows.filter(function (row) { return self.matchesSearch(row); });
  };

  Table.prototype.sortedRows = function () {
    var rows = this.filteredRows();
    if (!this.sortKey) { return rows; }
    var index = this.columnIndex(this.sortKey);
    var header = index >= 0 ? this.headers[index] : null;
    var type = header ? header.getAttribute('data-sla-sort-type') : 'text';
    var dir = this.sortDir;
    return rows.sort(function (r1, r2) {
      // Shared with the admin module's lookup tables — see assets/javascripts/sla_table_sort.js.
      // Read here rather than captured at parse time, so script order cannot matter.
      var shared = window.slaTableSort;
      return shared.compare(shared.cellValue(r1, index), shared.cellValue(r2, index), type, dir);
    });
  };

  // Shown in place of the table body when the search box has a value but nothing in the current
  // state-tab scope matches it — distinct from the empty-state row rendered by the ERB template,
  // which only appears when there were zero rows to begin with.
  Table.prototype.renderNoMatchRow = function (total) {
    if (!this.noMatchRow) {
      var td = document.createElement('td');
      td.colSpan = this.headers.length;
      td.className = 'tw-py-8 tw-text-center tw-text-gray-400';
      td.textContent = this.root.getAttribute('data-l-no-search-match') || 'No matches.';
      var tr = document.createElement('tr');
      tr.appendChild(td);
      this.noMatchRow = tr;
    }
    if (total === 0 && this.searchQuery) {
      this.tbody.appendChild(this.noMatchRow);
    } else if (this.noMatchRow.parentNode) {
      this.noMatchRow.parentNode.removeChild(this.noMatchRow);
    }
  };

  Table.prototype.render = function () {
    var sorted = this.sortedRows();
    var total = sorted.length;
    var pages = Math.max(1, Math.ceil(total / this.pageSize));
    if (this.page > pages) { this.page = pages; }
    var start = (this.page - 1) * this.pageSize;
    var end = Math.min(start + this.pageSize, total);

    // Hide everything first: sorted/paginated rows below only re-show the current page, and
    // rows filtered out by search never appear in `sorted` at all so must be hidden explicitly.
    this.rows.forEach(function (row) { row.style.display = 'none'; });
    for (var i = 0; i < sorted.length; i++) {
      this.tbody.appendChild(sorted[i]); // moves the node into sorted order
      sorted[i].style.display = (i >= start && i < end) ? '' : 'none';
    }

    this.renderIcons();
    this.renderNoMatchRow(total);
    this.renderPager(total, start, end, pages);
  };

  Table.prototype.renderIcons = function () {
    var self = this;
    this.headers.forEach(function (th) {
      var span = th.querySelector('.sla-sort-icon');
      if (!span) { return; }
      var active = th.getAttribute('data-sla-sort') === self.sortKey;
      var icons = window.slaTableSort.ICONS;
      span.innerHTML = active ? icons[self.sortDir] : icons.neutral;
      span.classList.toggle('tw-text-gray-600', active);
      span.classList.toggle('tw-text-gray-400', !active);
    });
  };

  Table.prototype.pageButton = function (label, page, opts) {
    var self = this;
    var base = 'tw-px-3 tw-py-1.5 tw-text-xs tw-font-medium tw-rounded-lg tw-border tw-border-solid tw-shadow-none tw-transition-colors ';
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = label;
    if (opts.active) {
      btn.className = base + 'tw-bg-primary-600 tw-text-white tw-border-primary-600';
    } else if (opts.disabled) {
      btn.className = base + 'tw-bg-white tw-text-gray-300 tw-border-gray-200 tw-cursor-not-allowed';
      btn.disabled = true;
    } else {
      btn.className = base + 'tw-bg-white tw-text-gray-700 tw-border-gray-300 hover:tw-bg-gray-50';
      btn.addEventListener('click', function () { self.page = page; self.render(); });
    }
    return btn;
  };

  Table.prototype.renderPager = function (total, start, end, pages) {
    if (!this.pager) { return; }
    this.pager.innerHTML = '';
    if (total === 0) { return; }

    var info = document.createElement('span');
    info.textContent = this.labels.showing + ' ' + (start + 1) + '–' + end + ' ' + this.labels.of + ' ' + total;
    this.pager.appendChild(info);

    if (pages <= 1) { return; }

    var nav = document.createElement('div');
    nav.className = 'tw-inline-flex tw-items-center tw-flex-wrap tw-gap-1';
    nav.appendChild(this.pageButton(this.labels.prev, this.page - 1, { disabled: this.page <= 1 }));
    var numbers = linkedPages(this.page, pages);
    var previous = null;
    for (var i = 0; i < numbers.length; i++) {
      var p = numbers[i];
      if (previous !== null && p !== previous + 1) { nav.appendChild(ellipsisSpacer()); }
      nav.appendChild(this.pageButton(String(p), p, { active: p === this.page }));
      previous = p;
    }
    nav.appendChild(this.pageButton(this.labels.next, this.page + 1, { disabled: this.page >= pages }));
    this.pager.appendChild(nav);
  };

  Table.prototype.bind = function () {
    var self = this;
    this.headers.forEach(function (th) {
      th.addEventListener('click', function () {
        var key = th.getAttribute('data-sla-sort');
        if (self.sortKey === key) {
          self.sortDir = self.sortDir === 'asc' ? 'desc' : 'asc';
        } else {
          self.sortKey = key;
          self.sortDir = 'asc';
        }
        self.page = 1;
        self.render();
      });
    });
    if (this.perPage) {
      this.perPage.addEventListener('change', function () {
        self.pageSize = self.readPageSize();
        self.page = 1;
        self.render();
      });
    }
    if (this.searchInput) {
      this.searchInput.addEventListener('input', function () {
        self.searchQuery = self.searchInput.value.trim().toLowerCase();
        self.page = 1;
        self.render();
      });
    }
  };

  // The visible Flowbite Dropdown button/menu is purely presentational - the real <select
  // data-sla-perpage> (now visually hidden) stays the one source of truth Table.prototype.bind
  // listens to above, so picking a menu item just updates that select's value and dispatches the
  // same `change` event a native picker would have fired, then updates the trigger button's own
  // label and closes the menu. Flowbite's Dropdown component handles the button<->menu toggle
  // open/positioning itself (data-dropdown-toggle, auto-initialized on window load) - this only
  // handles what happens once an option is actually clicked, which Flowbite's own dropdown always
  // leaves for the page to wire up itself.
  function initPerPageDropdown() {
    var select = byId('sla-detail-per-page');
    var trigger = byId('sla-detail-perpage-trigger');
    var menu = byId('sla-detail-perpage-menu');
    if (!select || !trigger || !menu) { return; }

    var label = trigger.querySelector('[data-sla-perpage-label]');

    menu.querySelectorAll('[data-sla-perpage-option]').forEach(function (option) {
      option.addEventListener('click', function () {
        var value = option.getAttribute('data-sla-perpage-option');
        select.value = value;
        select.dispatchEvent(new Event('change', { bubbles: true }));
        if (label) { label.textContent = value; }
        menu.classList.add('hidden');
      });
    });
  }

  // Expand/collapse the detail table into a modal. The ONE #sla-detail-table node is physically
  // moved from its in-card home into the modal body on expand (so rows are never duplicated) and
  // returned on close. Adding `.sla-detail-expanded` is what reveals the extra columns + the
  // search/per-page controls (partials/_detail_table.css); closing resets the page size back to
  // the compact default of 10 so the narrow in-card table never renders 50/100 rows.
  function initExpandModal(table) {
    var tableNode = byId('sla-detail-table');
    var home = byId('sla-detail-table-home');
    var modal = byId('sla-detail-modal');
    var body = byId('sla-detail-modal-body');
    var expandBtn = document.querySelector('[data-sla-detail-expand]');
    // Search + per-page: one node, moved onto the modal's pill row on expand and returned to the
    // top of the table node on close (see _detail_table.css for the matching visibility rule).
    var controls = document.querySelector('[data-sla-detail-controls]');
    var controlsSlot = modal ? modal.querySelector('[data-sla-modal-controls-slot]') : null;
    if (!tableNode || !home || !modal || !body || !expandBtn) { return; }

    // Point the (hidden) real <select> and its visible trigger label at `value` WITHOUT firing a
    // change event — the caller sets table.pageSize itself, so a dispatched change would just
    // double-apply. Used to park the control back on its default (10) whenever the modal closes.
    function syncPerPageControl(value) {
      var select = byId('sla-detail-per-page');
      if (select) { select.value = String(value); }
      var label = document.querySelector('#sla-detail-perpage-trigger [data-sla-perpage-label]');
      if (label) { label.textContent = String(value); }
    }

    function open() {
      body.appendChild(tableNode);
      if (controls && controlsSlot) { controlsSlot.appendChild(controls); }
      tableNode.classList.add('sla-detail-expanded');
      modal.classList.remove('hidden');
      document.body.style.overflow = 'hidden';
      if (table) {
        table.pageSize = table.readPageSize(); // modal follows the per-page dropdown (default 10)
        table.page = 1;
        table.render();
      }
    }

    function close() {
      home.appendChild(tableNode);
      // Back to where the ERB rendered it (first child), so the next expand finds it there again.
      if (controls) { tableNode.insertBefore(controls, tableNode.firstChild); }
      tableNode.classList.remove('sla-detail-expanded');
      modal.classList.add('hidden');
      document.body.style.overflow = '';
      try { sessionStorage.removeItem(MODAL_OPEN_KEY); } catch (e) { /* private mode */ }
      syncPerPageControl(10); // next modal open starts at 10 again
      if (table) {
        table.pageSize = COMPACT_PAGE_SIZE; // back to the compact 6-per-page in-card view
        table.page = 1;
        table.render();
      }
    }

    expandBtn.addEventListener('click', open);
    modal.querySelectorAll('[data-sla-detail-close]').forEach(function (el) {
      el.addEventListener('click', close);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !modal.classList.contains('hidden')) { close(); }
    });

    // The modal's own state pills are plain server links (same scope change as the compact card's):
    // clicking one reloads the whole page. Flag the modal as open first so init() re-opens it after
    // the reload, so filtering from inside the modal feels like it never left. The compact card's
    // pills deliberately carry no such flag, so they never spring the modal open.
    var modalTabs = modal.querySelector('[data-sla-modal-pills]');
    if (modalTabs) {
      modalTabs.querySelectorAll('a').forEach(function (link) {
        link.addEventListener('click', function () {
          try { sessionStorage.setItem(MODAL_OPEN_KEY, '1'); } catch (e) { /* private mode */ }
        });
      });
    }

    var reopen = false;
    try { reopen = sessionStorage.getItem(MODAL_OPEN_KEY) === '1'; } catch (e) { /* private mode */ }
    if (reopen) { open(); }
  }

  function init() {
    var root = byId('sla-detail-table');
    if (!root || root.slaDetailInitialized) { return; }
    root.slaDetailInitialized = true;

    var table = new Table(root);
    initPerPageDropdown();
    var hasRows = table.rows.length > 0;
    if (hasRows) { // empty-state row only — nothing to sort/paginate, but expand still works
      table.bind();
      table.render();
    }
    initExpandModal(hasRows ? table : null);
  }

  window.slaDashboardDetailTable = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
