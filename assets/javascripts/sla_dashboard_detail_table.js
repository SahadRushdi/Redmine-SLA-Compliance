/* Independent Open Tickets and SLA Trend detail tables: state filtering, search, sorting,
 * pagination and expand-to-modal behavior are scoped to each data-sla-detail-instance. */
(function () {
  'use strict';

  var COMPACT_PAGE_SIZE = 6;

  function linkedPages(current, pages) {
    var wanted = [1, current, pages];
    var p;
    for (p = current - 2; p <= current + 2; p += 1) {
      if (p > 1 && p < pages) { wanted.push(p); }
    }
    return wanted
      .filter(function (page, index) {
        return page >= 1 && page <= pages && wanted.indexOf(page) === index;
      })
      .sort(function (a, b) { return a - b; });
  }

  function ellipsisSpacer() {
    var span = document.createElement('span');
    span.className = 'tw-px-2 tw-py-1.5 tw-text-xs tw-text-gray-400 tw-select-none';
    span.textContent = '…';
    return span;
  }

  function Table(instance, root) {
    this.instance = instance;
    this.root = root;
    this.tbody = root.querySelector('[data-sla-detail-tbody]');
    this.rows = this.tbody ? Array.prototype.slice.call(this.tbody.querySelectorAll('tr[data-sla-row]')) : [];
    this.headers = Array.prototype.slice.call(root.querySelectorAll('thead th[data-sla-sort]'));
    this.pager = root.querySelector('[data-sla-detail-pagination]');
    this.perPage = root.querySelector('[data-sla-perpage]');
    this.searchInput = root.querySelector('[data-sla-detail-search]');
    this.noMatchRow = null;
    this.pageSize = COMPACT_PAGE_SIZE;
    this.page = 1;
    this.sortKey = null;
    this.sortDir = 'asc';

    var activePill = instance.querySelector('[data-sla-state-filter].is-active');
    this.stateFilter = activePill ? activePill.getAttribute('data-sla-state-filter') : 'all';
    this.searchQuery = this.searchInput ? this.searchInput.value.trim().toLowerCase() : '';
    this.labels = this.pager ? {
      showing: this.pager.getAttribute('data-l-showing') || 'Showing',
      of: this.pager.getAttribute('data-l-of') || 'of',
      prev: this.pager.getAttribute('data-l-prev') || 'Previous',
      next: this.pager.getAttribute('data-l-next') || 'Next'
    } : {};
  }

  Table.prototype.readPageSize = function () {
    var value = this.perPage ? parseInt(this.perPage.value, 10) : 10;
    return (value && value > 0) ? value : 10;
  };

  Table.prototype.columnIndex = function (key) {
    var i;
    for (i = 0; i < this.headers.length; i += 1) {
      if (this.headers[i].getAttribute('data-sla-sort') === key) { return i; }
    }
    return -1;
  };

  Table.prototype.matchesSearch = function (row) {
    if (!this.searchQuery) { return true; }
    var haystack = row.getAttribute('data-sla-search') || row.textContent || '';
    return haystack.toLowerCase().indexOf(this.searchQuery) !== -1;
  };

  Table.prototype.matchesState = function (row) {
    if (this.stateFilter === 'all') { return true; }
    if (this.stateFilter === 'at_risk') {
      return row.getAttribute('data-sla-at-risk') === 'true';
    }
    return row.getAttribute('data-sla-state') === this.stateFilter;
  };

  Table.prototype.filteredRows = function () {
    var self = this;
    return this.rows.filter(function (row) {
      return self.matchesState(row) && self.matchesSearch(row);
    });
  };

  Table.prototype.sortedRows = function () {
    var rows = this.filteredRows();
    if (!this.sortKey) { return rows; }
    var index = this.columnIndex(this.sortKey);
    var header = index >= 0 ? this.headers[index] : null;
    var type = header ? header.getAttribute('data-sla-sort-type') : 'text';
    var dir = this.sortDir;
    return rows.sort(function (left, right) {
      return window.slaTableSort.compare(
        window.slaTableSort.cellValue(left, index),
        window.slaTableSort.cellValue(right, index), type, dir
      );
    });
  };

  Table.prototype.renderNoMatchRow = function (total) {
    if (!this.noMatchRow) {
      var td = document.createElement('td');
      td.colSpan = this.headers.length;
      td.className = 'tw-py-8 tw-text-center tw-text-gray-400';
      var tr = document.createElement('tr');
      tr.appendChild(td);
      this.noMatchRow = tr;
    }
    if (total === 0 && (this.searchQuery || this.stateFilter !== 'all')) {
      var key = this.searchQuery ? 'data-l-no-search-match' : 'data-l-empty';
      this.noMatchRow.firstChild.textContent = this.root.getAttribute(key) || 'No matches.';
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
    var i;

    this.rows.forEach(function (row) { row.style.display = 'none'; });
    for (i = 0; i < sorted.length; i += 1) {
      this.tbody.appendChild(sorted[i]);
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
      span.innerHTML = active ? window.slaTableSort.ICONS[self.sortDir] : window.slaTableSort.ICONS.neutral;
      span.classList.toggle('tw-text-gray-600', active);
      span.classList.toggle('tw-text-gray-400', !active);
    });
  };

  Table.prototype.pageButton = function (label, page, opts) {
    var self = this;
    var base = 'tw-px-3 tw-py-1.5 tw-text-xs tw-font-medium tw-rounded-lg tw-border tw-border-solid tw-shadow-none tw-transition-colors ';
    var button = document.createElement('button');
    button.type = 'button';
    button.textContent = label;
    if (opts.active) {
      button.className = base + 'tw-bg-primary-600 tw-text-white tw-border-primary-600';
    } else if (opts.disabled) {
      button.className = base + 'tw-bg-white tw-text-gray-300 tw-border-gray-200 tw-cursor-not-allowed';
      button.disabled = true;
    } else {
      button.className = base + 'tw-bg-white tw-text-gray-700 tw-border-gray-300 hover:tw-bg-gray-50';
      button.addEventListener('click', function () {
        self.page = page;
        self.render();
      });
    }
    return button;
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
    var i;
    for (i = 0; i < numbers.length; i += 1) {
      if (previous !== null && numbers[i] !== previous + 1) { nav.appendChild(ellipsisSpacer()); }
      nav.appendChild(this.pageButton(String(numbers[i]), numbers[i], { active: numbers[i] === this.page }));
      previous = numbers[i];
    }
    nav.appendChild(this.pageButton(this.labels.next, this.page + 1, { disabled: this.page >= pages }));
    this.pager.appendChild(nav);
  };

  Table.prototype.setState = function (state) {
    this.stateFilter = state;
    this.page = 1;
    this.instance.querySelectorAll('[data-sla-state-filter]').forEach(function (pill) {
      pill.classList.toggle('is-active', pill.getAttribute('data-sla-state-filter') === state);
    });
    this.render();
  };

  Table.prototype.bind = function () {
    var self = this;
    this.instance.querySelectorAll('[data-sla-state-filter]').forEach(function (pill) {
      pill.addEventListener('click', function () {
        self.setState(pill.getAttribute('data-sla-state-filter'));
      });
    });
    this.headers.forEach(function (header) {
      header.addEventListener('click', function () {
        var key = header.getAttribute('data-sla-sort');
        self.sortDir = self.sortKey === key && self.sortDir === 'asc' ? 'desc' : 'asc';
        if (self.sortKey !== key) { self.sortDir = 'asc'; }
        self.sortKey = key;
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

  function initPerPageDropdown(instance) {
    var select = instance.querySelector('[data-sla-perpage]');
    var trigger = instance.querySelector('[data-sla-perpage-trigger]');
    var menu = instance.querySelector('[data-sla-perpage-menu]');
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

  function initExpandModal(instance, table) {
    var tableNode = instance.querySelector('[data-sla-detail-table]');
    var home = instance.querySelector('[data-sla-detail-home]');
    var modal = instance.querySelector('[data-sla-detail-modal]');
    var body = instance.querySelector('[data-sla-detail-modal-body]');
    var expandButton = instance.querySelector('[data-sla-detail-expand]');
    var controls = instance.querySelector('[data-sla-detail-controls]');
    var controlsSlot = instance.querySelector('[data-sla-modal-controls-slot]');
    if (!tableNode || !home || !modal || !body || !expandButton) { return; }

    function syncPerPageControl(value) {
      var select = instance.querySelector('[data-sla-perpage]');
      var label = instance.querySelector('[data-sla-perpage-label]');
      if (select) { select.value = String(value); }
      if (label) { label.textContent = String(value); }
    }

    function open() {
      body.appendChild(tableNode);
      if (controls && controlsSlot) { controlsSlot.appendChild(controls); }
      tableNode.classList.add('sla-detail-expanded');
      modal.classList.remove('hidden');
      document.body.style.overflow = 'hidden';
      if (table) {
        table.pageSize = table.readPageSize();
        table.page = 1;
        table.render();
      }
    }

    function close() {
      home.appendChild(tableNode);
      if (controls) { tableNode.insertBefore(controls, tableNode.firstChild); }
      tableNode.classList.remove('sla-detail-expanded');
      modal.classList.add('hidden');
      document.body.style.overflow = '';
      syncPerPageControl(10);
      if (table) {
        table.pageSize = COMPACT_PAGE_SIZE;
        table.page = 1;
        table.render();
      }
    }

    expandButton.addEventListener('click', open);
    modal.querySelectorAll('[data-sla-detail-close]').forEach(function (element) {
      element.addEventListener('click', close);
    });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && !modal.classList.contains('hidden')) { close(); }
    });
  }

  function initInstance(instance) {
    if (instance.slaDetailInitialized) { return; }
    instance.slaDetailInitialized = true;
    var root = instance.querySelector('[data-sla-detail-table]');
    if (!root) { return; }

    var table = new Table(instance, root);
    initPerPageDropdown(instance);
    if (table.rows.length > 0) {
      table.bind();
      table.render();
    }
    initExpandModal(instance, table.rows.length > 0 ? table : null);
  }

  function init() {
    document.querySelectorAll('[data-sla-detail-instance]').forEach(initInstance);
  }

  window.slaDashboardDetailTable = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
