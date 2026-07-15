/* SLA access allow-list pickers (Step 5.1). Loaded only on Administration → Plugins →
 * SLA Compliance. Kept separate from sla_policy_form.js, which is scoped to the Project
 * Settings page and early-returns on anything else.
 *
 * Two things live per list (viewer / manager), tied together by a shared `[data-sla-access-list]`
 * container:
 *   1. A remote Tom Select search box (`select[data-sla-user-search]`) used to find and pick a
 *      user -- picking one adds them to state below and shows the normal Tom Select pill as pick
 *      confirmation, then the box clears itself shortly after (CLEAR_DELAY_MS): the pill isn't
 *      meant to be preserved once the user has been added to the table below.
 *   2. A plain sortable/paginated table (`[data-sla-rows]` etc.) that is the single lasting place
 *      a granted user is shown, with a delete button per row. The server renders a read-only,
 *      unsorted, unpaginated version of this table (and the matching hidden inputs) as a no-JS
 *      fallback; the moment this file boots it takes over both and becomes the source of truth.
 */
(function () {
  'use strict';

  var PAGE_SIZE = 10;
  // How long the picked user's pill stays visible in the search box before it self-clears.
  var CLEAR_DELAY_MS = 350;

  function escapeHtml(value) {
    var div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  }

  // Redmine's own linked_pages algorithm (lib/redmine/pagination.rb): first page, current page,
  // last page, plus up to two pages either side of the current one -- so long lists collapse to
  // "1 … 4 5 6 … 20" instead of one link per page.
  function linkedPages(page, totalPages) {
    if (totalPages <= 1) { return []; }
    var pages = [1, page, totalPages];
    for (var p = page - 2; p <= page + 2; p++) {
      if (p > 1 && p < totalPages) { pages.push(p); }
    }
    pages = pages.filter(function (p, i) { return pages.indexOf(p) === i; }).sort(function (a, b) {
      return a - b;
    });
    return pages;
  }

  // Owns one list's state (items + sort + page) and keeps the table, the hidden inputs, and the
  // pagination controls in sync with it. Returns an `addItem` hook the Tom Select handler calls.
  function initAccessList(container) {
    var listName = container.getAttribute('data-sla-access-list');
    var seed;
    try {
      seed = JSON.parse(container.getAttribute('data-sla-users') || '[]');
    } catch (e) {
      seed = [];
    }

    var state = { items: seed, sortKey: 'name', sortDir: 'asc', page: 1 };

    var hiddenInputsEl = container.querySelector('[data-sla-hidden-inputs]');
    var rowsEl = container.querySelector('[data-sla-rows]');
    var emptyEl = container.querySelector('[data-sla-empty]');
    var paginationEl = container.querySelector('[data-sla-pagination]');
    var headers = container.querySelectorAll('[data-sla-sort]');
    var hiddenInputName = 'settings[sla_' + listName + '_user_ids][]';

    function sortedItems() {
      var items = state.items.slice();
      items.sort(function (a, b) {
        var av = (a[state.sortKey] || '').toString().toLowerCase();
        var bv = (b[state.sortKey] || '').toString().toLowerCase();
        if (av === bv) { return 0; }
        var lower = av < bv;
        return (state.sortDir === 'asc') === lower ? -1 : 1;
      });
      return items;
    }

    function syncHiddenInputs() {
      hiddenInputsEl.innerHTML = state.items.map(function (item) {
        return '<input type="hidden" name="' + hiddenInputName + '" value="' +
          escapeHtml(item.id) + '">';
      }).join('');
    }

    function renderRows(pageItems) {
      rowsEl.innerHTML = pageItems.map(function (item) {
        // Same convention Redmine core uses everywhere for an inline, client-only remove action
        // (e.g. app/views/attachments/_form.html.erb) -- an `icon-only icon-del` link, not a
        // Flowbite-style button, so Purplemine2's own (unscoped) icon/colour CSS styles it exactly
        // like every other delete icon in the app, no custom CSS of ours involved.
        return '<tr class="tw-border-b tw-border-gray-100 last:tw-border-0">' +
          '<td class="tw-p-1.5">' + escapeHtml(item.name) + '</td>' +
          '<td class="tw-p-1.5">' + escapeHtml(item.login) + '</td>' +
          '<td class="tw-p-1.5">' + escapeHtml(item.mail) + '</td>' +
          '<td class="tw-p-1.5 tw-text-right">' +
          '<a href="#" class="icon-only icon-del" data-sla-remove="' + escapeHtml(item.id) +
          '" title="Remove">Remove</a></td></tr>';
      }).join('');
    }

    // Same markup Redmine::Pagination::Helper#pagination_links_full renders (lib/redmine/
    // pagination.rb) -- <ul class="pages"> of <li class="previous|page|current|next|spacer">,
    // then a "(first-last/total)" items span -- just with data-sla-page click handlers standing
    // in for real page-query links, since this table never leaves the settings form.
    function renderPagination(total, totalPages) {
      var itemsLabel = total === 0 ? '(0-0/0)' :
        '(' + ((state.page - 1) * PAGE_SIZE + 1) + '-' +
        Math.min(state.page * PAGE_SIZE, total) + '/' + total + ')';

      var pagesHtml = '';
      if (totalPages > 1) {
        pagesHtml += state.page > 1
          ? '<li class="previous page"><a href="#" data-sla-page="' + (state.page - 1) +
            '">&#171; Previous</a></li>'
          : '<li class="previous"><span>&#171; Previous</span></li>';

        var previous = null;
        linkedPages(state.page, totalPages).forEach(function (page) {
          if (previous !== null && previous !== page - 1) {
            pagesHtml += '<li class="spacer"><span>&hellip;</span></li>';
          }
          pagesHtml += page === state.page
            ? '<li class="current"><span>' + page + '</span></li>'
            : '<li class="page"><a href="#" data-sla-page="' + page + '">' + page + '</a></li>';
          previous = page;
        });

        pagesHtml += state.page < totalPages
          ? '<li class="next page"><a href="#" data-sla-page="' + (state.page + 1) +
            '">Next &#187;</a></li>'
          : '<li class="next"><span>Next &#187;</span></li>';
      }

      paginationEl.innerHTML =
        (pagesHtml ? '<ul class="pages">' + pagesHtml + '</ul>' : '') +
        '<span><span class="items">' + itemsLabel + '</span></span>';
    }

    function renderSortIndicators() {
      headers.forEach(function (th) {
        var indicator = th.querySelector('[data-sla-sort-indicator]');
        if (!indicator) { return; }
        indicator.textContent = th.getAttribute('data-sla-sort') !== state.sortKey ? '' :
          (state.sortDir === 'asc' ? '▲' : '▼');
      });
    }

    function render() {
      syncHiddenInputs();

      var items = sortedItems();
      var totalPages = Math.max(1, Math.ceil(items.length / PAGE_SIZE));
      if (state.page > totalPages) { state.page = totalPages; }
      var start = (state.page - 1) * PAGE_SIZE;

      emptyEl.classList.toggle('hidden', items.length > 0);
      renderRows(items.slice(start, start + PAGE_SIZE));
      renderSortIndicators();
      renderPagination(items.length, totalPages);
    }

    rowsEl.addEventListener('click', function (e) {
      var link = e.target.closest('[data-sla-remove]');
      if (!link) { return; }
      e.preventDefault();

      var id = link.getAttribute('data-sla-remove');
      state.items = state.items.filter(function (item) { return String(item.id) !== id; });
      render();
    });

    headers.forEach(function (th) {
      th.addEventListener('click', function () {
        var key = th.getAttribute('data-sla-sort');
        state.sortDir = state.sortKey === key && state.sortDir === 'asc' ? 'desc' : 'asc';
        state.sortKey = key;
        state.page = 1;
        render();
      });
    });

    paginationEl.addEventListener('click', function (e) {
      var link = e.target.closest('[data-sla-page]');
      if (!link) { return; }
      e.preventDefault();
      state.page = parseInt(link.getAttribute('data-sla-page'), 10);
      render();
    });

    render();

    return {
      addItem: function (item) {
        var exists = state.items.some(function (existing) {
          return String(existing.id) === String(item.id);
        });
        if (exists) { return; }
        state.items.push(item);
        render();
      }
    };
  }

  function initUserPickers() {
    document.querySelectorAll('[data-sla-access-list]').forEach(function (container) {
      if (container.slaAccessListReady) { return; }
      container.slaAccessListReady = true;
      var list = initAccessList(container);

      var select = container.querySelector('select[data-sla-user-search]');
      if (!select || select.tomselect || !window.TomSelect) { return; }

      var url = select.getAttribute('data-sla-user-search');

      var tomSelect = new TomSelect(select, {
        valueField: 'id',
        labelField: 'name',
        searchField: ['name', 'login'],
        create: false,
        persist: false,
        // Keep the dropdown open across picks so several users can be added in a row without
        // reopening it each time.
        closeAfterSelect: false,
        // Show a first page of users on focus, so the picker is usable without knowing a name.
        preload: 'focus',
        // Redmine's Principal.like already matches login/name/email server-side; scoring the
        // results again client-side would hide valid matches (e.g. an email-only hit).
        score: function () { return function () { return 1; }; },
        load: function (query, callback) {
          fetch(url + '?q=' + encodeURIComponent(query), {
            credentials: 'same-origin',
            headers: { Accept: 'application/json' }
          })
            .then(function (response) {
              if (!response.ok) { throw new Error(response.status); }
              return response.json();
            })
            .then(callback)
            // Never leave the picker stuck in a loading state on a failed lookup.
            .catch(function () { callback(); });
        },
        render: {
          option: function (item, escape) {
            return '<div>' + escape(item.name) +
              ' <span class="tw-text-gray-500">(' + escape(item.login) + ')</span></div>';
          }
        },
        onItemAdd: function (value) {
          var picked = tomSelect.options[value];
          list.addItem({
            id: picked.id, name: picked.name, login: picked.login, mail: picked.mail
          });
          // Let Tom Select show its normal pill first (pick confirmation), then clear it -- the
          // table row added above is the lasting record, the pill doesn't need to persist.
          window.setTimeout(function () { tomSelect.clear(true); }, CLEAR_DELAY_MS);
        }
      });
    });
  }

  document.addEventListener('DOMContentLoaded', initUserPickers);
})();
