/* SLA policy settings-tab behaviour (Phase 4). Loaded only on the Project Settings page.
 * init() is idempotent and re-invoked from edit.js.erb after AJAX re-renders; event handlers
 * are delegated (bound once) so replaced DOM keeps working. Config strings/URLs come from
 * data- attributes on #sla-policy-form — no ERB in this asset. */
(function () {
  'use strict';

  var state = { bound: false, section: '', tracker: '', recalculationTimer: null,
                reloadAfterRecalculation: false, revertTrigger: null };

  function byId(id) { return document.getElementById(id); }

  // --- Historical recalculation progress ----------------------------------------------------
  function stopRecalculationPolling() {
    window.clearTimeout(state.recalculationTimer);
    state.recalculationTimer = null;
  }

  function renderRecalculationProgress(container, data) {
    if (!container || data.status === 'idle') {
      if (container) { container.classList.add('hidden'); }
      stopRecalculationPolling();
      return;
    }

    var percentage = Math.max(0, Math.min(100, Number(data.progress) || 0));
    var status = data.status || 'queued';
    var statusText = container.querySelector('[data-sla-recalculation-status]');
    var percentText = container.querySelector('[data-sla-recalculation-percent]');
    var fill = container.querySelector('[data-sla-recalculation-fill]');
    var progressbar = container.querySelector('[role="progressbar"]');

    container.classList.remove('hidden');
    container.setAttribute('data-status', status);
    if (data.run_token) { container.setAttribute('data-run-token', data.run_token); }
    if (statusText) { statusText.textContent = data.message || ''; }
    if (percentText) { percentText.textContent = percentage + '%'; }
    if (fill) { fill.style.width = percentage + '%'; }
    if (progressbar) { progressbar.setAttribute('aria-valuenow', String(percentage)); }

    if (status === 'completed' || status === 'failed') {
      stopRecalculationPolling();
      if (status === 'completed' && state.reloadAfterRecalculation) {
        state.reloadAfterRecalculation = false;
        window.setTimeout(function () { window.location.reload(); }, 700);
      }
    }
  }

  function pollRecalculationProgress() {
    var container = byId('sla-recalculation-progress');
    if (!container) { return; }

    stopRecalculationPolling();
    var url = new URL(container.getAttribute('data-status-url'), window.location.origin);
    var token = container.getAttribute('data-run-token');
    if (token) { url.searchParams.set('run_token', token); }

    window.fetch(url.toString(), { credentials: 'same-origin', headers: { Accept: 'application/json' } })
      .then(function (response) {
        if (!response.ok) { throw new Error('Unable to read recalculation progress'); }
        return response.json();
      })
      .then(function (data) {
        renderRecalculationProgress(container, data);
        if (data.status === 'queued' || data.status === 'running') {
          state.recalculationTimer = window.setTimeout(pollRecalculationProgress, 1500);
        }
      })
      .catch(function () {
        // A transient request failure must not claim that the background work itself failed.
        state.recalculationTimer = window.setTimeout(pollRecalculationProgress, 3000);
      });
  }

  function startRecalculationPolling(runToken) {
    var container = byId('sla-recalculation-progress');
    if (!container) { return; }
    if (runToken) { container.setAttribute('data-run-token', runToken); }
    container.classList.remove('hidden');
    pollRecalculationProgress();
  }

  function runHistoricalRecalculation() {
    var form = byId('sla-policy-form');
    var button = document.querySelector('[data-sla-recalculate-button]');
    var checkbox = form && form.querySelector('input[name="recalculate"]');
    if (!form || !button || !checkbox || !checkbox.checked) { return; }
    button.disabled = true;

    jQuery.ajax({
      url: form.getAttribute('data-recalculate-url'),
      method: 'POST',
      dataType: 'json',
      headers: csrfHeaders()
    }).done(function (response) {
      state.reloadAfterRecalculation = true;
      startRecalculationPolling(response.recalculation.run_token);
    }).fail(function (xhr) {
      var response = xhr.responseJSON || {};
      window.alert(response.error || 'Unable to recalculate historical tickets');
      button.disabled = false;
    });
  }

  // --- Sidebar section navigation ------------------------------------------------------------
  // The sections are all in the DOM; switching only toggles visibility, so an unsaved edit in one
  // section survives a look at another. The sidebar's links keep working without JS (they carry
  // ?section=...), which is why the click handler has to preventDefault here.

  // The server-rendered truth: which nav link came back marked active.
  function domSection() {
    var active = document.querySelector('[data-sla-section-link].is-active');
    return active ? active.getAttribute('data-sla-section-link') : '';
  }

  function currentSection() {
    return state.section || domSection();
  }

  function activateSection(key) {
    if (!key) { return; }
    state.section = key;

    document.querySelectorAll('[data-sla-panel]').forEach(function (panel) {
      panel.classList.toggle('hidden', panel.getAttribute('data-sla-panel') !== key);
    });
    document.querySelectorAll('[data-sla-section-link]').forEach(function (link) {
      var active = link.getAttribute('data-sla-section-link') === key;
      link.classList.toggle('is-active', active);
      link.setAttribute('aria-current', active ? 'page' : 'false');
    });

    // Keep the address bar on the open section so a reload, a bookmark, or the redirect after a
    // save all land back where the user was. Only `section` is written: Redmine carries the tab
    // in the PATH (/projects/x/settings/sla_policy), so also setting a `tab` query param would
    // just append a redundant duplicate that path params win over anyway.
    if (window.history && window.history.replaceState) {
      var url = new URL(window.location.href);
      url.searchParams.set('section', key);
      window.history.replaceState({}, '', url.toString());
    }
  }

  // Open the list UPWARDS when it wouldn't fit below the control in the viewport. The dropdown is
  // absolutely positioned inside its card (deliberately not body-parented: our styling for it is
  // scoped to .sla-plugin and would not follow it out), so a list on the last row of the Priority
  // Targets table would otherwise open off the bottom of the screen. `sla-ts-drop-up` flips it in
  // CSS; see partials/_tom_select.css. Re-measured on every open, since row position and list
  // length both change as the user filters.
  function bindDropUp(instance) {
    // Suppress the list Redmine's own defaultFocus() would otherwise pop open on load — see
    // assets/javascripts/sla_tom_select.js. Every instance in this file is built through here.
    if (window.slaTomSelect) { window.slaTomSelect.guard(instance); }

    instance.on('dropdown_open', function (dropdown) {
      // Keep the unbounded clone-project list out of the document flow. It overlays the viewport,
      // so opening it does not increase the General tab's scroll height.
      if (instance.wrapper.classList.contains('sla-clone-project-select')) {
        instance.wrapper.classList.remove('sla-ts-drop-up');
        var cloneControlRect = instance.control.getBoundingClientRect();
        var cloneDropdownHeight = dropdown.offsetHeight;
        var cloneRoomBelow = window.innerHeight - cloneControlRect.bottom - 8;
        var cloneTop = cloneControlRect.bottom + 4;
        if (cloneDropdownHeight > cloneRoomBelow && cloneControlRect.top > cloneRoomBelow) {
          cloneTop = Math.max(8, cloneControlRect.top - cloneDropdownHeight - 4);
        }
        dropdown.style.position = 'fixed';
        dropdown.style.left = cloneControlRect.left + 'px';
        dropdown.style.top = cloneTop + 'px';
        dropdown.style.bottom = 'auto';
        dropdown.style.right = 'auto';
        dropdown.style.width = cloneControlRect.width + 'px';
        return;
      }
      var rect = instance.control.getBoundingClientRect();
      var needed = dropdown.offsetHeight;
      var roomBelow = window.innerHeight - rect.bottom;
      var flip = roomBelow < needed && rect.top > roomBelow;
      instance.wrapper.classList.toggle('sla-ts-drop-up', flip);
    });
    instance.on('dropdown_close', function () {
      instance.wrapper.classList.remove('sla-ts-drop-up');
    });
    return instance;
  }

  function initChips() {
    document.querySelectorAll('select[data-sla-chips]').forEach(function (el) {
      if (!el.tomselect && window.TomSelect) {
        var instance = bindDropUp(new TomSelect(el, {
          plugins: { remove_button: { title: '' } },
          placeholder: el.getAttribute('placeholder') || ''
        }));
        var removeNativeTooltips = function () {
          instance.control.querySelectorAll('.remove').forEach(function (button) {
            button.removeAttribute('title');
            button.setAttribute('aria-label', 'Remove');
          });
        };
        removeNativeTooltips();
        instance.on('item_add', removeNativeTooltips);
      }
    });
  }

  function initEmailChips() {
    if (window.slaTomSelect) { window.slaTomSelect.initEmailChips(bindDropUp); }
  }

  // Single-value dropdowns (Tracker and stale-digest frequency). Native <select> popups are
  // themed to match the rest of the scoped Flowbite UI — Tom Select replaces them with the same
  // styled, HTML-rendered dropdown already used for the chip multi-selects (see .ts-dropdown in
  // tailwind.input.css), which also sidesteps the native-select text-clipping some browsers
  // exhibit under Purplemine2's fixed input height. Tom Select keeps the original <select>'s
  // `.value` in sync and re-dispatches `change` on it.
  function initSingleSelects() {
    document.querySelectorAll('select[data-sla-select]').forEach(function (el) {
      if (!el.tomselect && window.TomSelect) {
        bindDropUp(new TomSelect(el, { create: false, allowEmptyOption: true }));
      }
    });
  }

  // --- SLA Targets: one Priority Targets table per selected tracker --------------------------
  // Adding a tracker fetches ONLY that tracker's table and inserts it; removing one just detaches
  // its table. Deliberately not a re-render of the whole section: targets already chosen for the
  // other selected trackers are unsaved DOM state and must survive. Removing a table also stops
  // its fields posting, which is what makes "hidden = not written" true on the server side too
  // (SlaPoliciesController#replace_tracker_definitions!) — a hidden tracker keeps its stored
  // targets rather than losing them.
  function syncDefinitionTables(select) {
    var wanted = Array.prototype.map.call(select.selectedOptions, function (option) {
      return option.value;
    });

    document.querySelectorAll('[data-sla-definition-table]').forEach(function (table) {
      if (wanted.indexOf(table.getAttribute('data-sla-definition-table')) === -1) {
        table.parentNode.removeChild(table);
      }
    });

    wanted.forEach(function (trackerId) {
      if (byId('sla-definitions-table-' + trackerId)) { return; }
      state.tracker = trackerId;
      jQuery.ajax({
        url: select.getAttribute('data-table-url'),
        data: { tracker_id: trackerId, section: currentSection() },
        dataType: 'script'
      });
    });
    if (wanted.indexOf(state.tracker) === -1) { state.tracker = wanted[0] || ''; }
    renderTrackerTabs(select);
  }

  function activateTracker(trackerId) {
    state.tracker = trackerId || '';
    document.querySelectorAll('[data-sla-tracker-tab]').forEach(function (tab) {
      var active = tab.getAttribute('data-sla-tracker-tab') === state.tracker;
      tab.classList.toggle('is-active', active);
      tab.setAttribute('aria-selected', active ? 'true' : 'false');
    });
    document.querySelectorAll('[data-sla-definition-table]').forEach(function (table) {
      table.classList.toggle('hidden', table.getAttribute('data-sla-definition-table') !== state.tracker);
    });
    var source = byId('sla-clone-tracker-source');
    if (source && source.value === state.tracker) {
      if (source.tomselect) { source.tomselect.clear(true); } else { source.value = ''; }
    }
  }

  function renderTrackerTabs(select) {
    var bar = byId('sla-tracker-tabs');
    if (!bar || !select) { return; }
    var options = Array.prototype.slice.call(select.selectedOptions);
    if (!state.tracker || !options.some(function (option) { return option.value === state.tracker; })) {
      state.tracker = options.length ? options[0].value : '';
    }
    bar.innerHTML = '';
    options.forEach(function (option) {
      var button = document.createElement('button');
      button.type = 'button';
      button.setAttribute('role', 'tab');
      button.setAttribute('data-sla-tracker-tab', option.value);
      button.className = 'sla-tracker-tab';
      button.textContent = option.textContent;
      bar.appendChild(button);
    });
    activateTracker(state.tracker);
  }

  function trackerManager() { return byId('sla-tracker-manager'); }

  function csrfHeaders() {
    var token = document.querySelector('meta[name="csrf-token"]');
    return token ? { 'X-CSRF-Token': token.content } : {};
  }

  function openAddTrackerMenu() {
    var modal = byId('sla-add-tracker-menu');
    if (!modal) { return; }
    modal.classList.remove('hidden');
    var first = modal.querySelector('[data-sla-add-tracker]');
    if (first) { first.focus(); }
  }

  function closeAddTrackerMenu() {
    var modal = byId('sla-add-tracker-menu');
    if (modal) { modal.classList.add('hidden'); }
  }

  function buildTrackerTab(id, name) {
    var wrapper = document.createElement('div');
    wrapper.className = 'sla-tracker-tab-wrap';
    var tab = document.createElement('button');
    tab.type = 'button';
    tab.setAttribute('role', 'tab');
    tab.setAttribute('data-sla-tracker-tab', id);
    tab.setAttribute('data-tracker-name', name);
    tab.setAttribute('aria-selected', 'false');
    tab.className = 'sla-tracker-tab';
    tab.textContent = name;
    var remove = document.createElement('button');
    remove.type = 'button';
    remove.setAttribute('data-sla-remove-tracker', '');
    remove.setAttribute('aria-label', 'Remove ' + name);
    remove.textContent = '×';
    wrapper.appendChild(tab);
    wrapper.appendChild(remove);
    return wrapper;
  }

  function syncTrackerManagerVisibility() {
    var tabs = document.querySelectorAll('[data-sla-tracker-tab]');
    var empty = byId('sla-tracker-empty');
    var content = byId('sla-tracker-content');
    if (empty) { empty.classList.toggle('hidden', tabs.length > 0); }
    if (content) { content.classList.toggle('hidden', tabs.length === 0); }
    document.querySelectorAll('[data-sla-add-tracker-toggle]').forEach(function (button) {
      button.classList.toggle('hidden', !document.querySelector('[data-sla-add-tracker]'));
    });
  }

  function addTracker(button) {
    var manager = trackerManager();
    if (!manager || button.disabled) { return; }
    button.disabled = true;
    var id = button.getAttribute('data-sla-add-tracker');
    var name = button.getAttribute('data-tracker-name');
    jQuery.ajax({
      url: manager.getAttribute('data-add-endpoint'), method: 'PATCH', dataType: 'json',
      headers: csrfHeaders(), data: { tracker_id: id }
    }).done(function (response) {
      var tabs = byId('sla-tracker-tabs');
      var addButton = tabs && tabs.querySelector('[data-sla-add-tracker-toggle]');
      if (tabs && !document.querySelector('[data-sla-tracker-tab="' + id + '"]')) {
        tabs.insertBefore(buildTrackerTab(id, name), addButton);
      }
      button.parentNode.removeChild(button);
      closeAddTrackerMenu();
      syncTrackerManagerVisibility();
      jQuery.ajax({ url: response.table_url, dataType: 'script' }).done(function () {
        activateTracker(id);
      }).fail(function () {
        // Membership is already durable; reload into the server-rendered source of truth rather
        // than leaving a tab with no table after a transient render request failure.
        window.location.reload();
      });
    }).fail(function (xhr) {
      button.disabled = false;
      window.alert((xhr.responseJSON || {}).error || 'Unable to add tracker');
    });
  }

  function openRemoveTrackerModal(tab) {
    var modal = byId('sla-remove-tracker-modal');
    if (!modal) { return; }
    modal.setAttribute('data-tracker-id', tab.getAttribute('data-sla-tracker-tab'));
    modal.setAttribute('data-tracker-name', tab.getAttribute('data-tracker-name'));
    var titleTemplate = modal.getAttribute('data-title-template') || 'Remove tracker "%{tracker}"';
    var template = modal.getAttribute('data-confirm-template') || 'Delete tracker %{tracker}?';
    modal.querySelector('#sla-remove-tracker-title').textContent =
      titleTemplate.replace('%{tracker}', tab.getAttribute('data-tracker-name'));
    modal.querySelector('[data-sla-remove-message]').textContent =
      template.replace('%{tracker}', tab.getAttribute('data-tracker-name'));
    modal.classList.remove('hidden');
    modal.querySelector('[data-sla-remove-confirm]').focus();
  }

  function closeRemoveTrackerModal() {
    var modal = byId('sla-remove-tracker-modal');
    if (modal) { modal.classList.add('hidden'); }
  }

  function removeTracker() {
    var manager = trackerManager();
    var modal = byId('sla-remove-tracker-modal');
    if (!manager || !modal) { return; }
    var id = modal.getAttribute('data-tracker-id');
    var name = modal.getAttribute('data-tracker-name');
    jQuery.ajax({
      url: manager.getAttribute('data-remove-endpoint'), method: 'DELETE', dataType: 'json',
      headers: csrfHeaders(), data: { tracker_id: id }
    }).done(function () {
      var tab = document.querySelector('[data-sla-tracker-tab="' + id + '"]');
      var table = byId('sla-definitions-table-' + id);
      if (tab) { tab.parentNode.parentNode.removeChild(tab.parentNode); }
      if (table) { table.parentNode.removeChild(table); }
      var options = document.querySelector('[data-sla-add-tracker-options]');
      if (options) {
        var option = document.createElement('button');
        option.type = 'button';
        option.setAttribute('data-sla-add-tracker', id);
        option.setAttribute('data-tracker-name', name);
        option.className = 'tw-w-full tw-rounded-lg tw-border tw-border-gray-200 tw-bg-white tw-px-4 tw-py-3 tw-text-left tw-text-sm tw-text-gray-900 hover:tw-bg-gray-50';
        option.textContent = name;
        options.appendChild(option);
      }
      closeRemoveTrackerModal();
      syncTrackerManagerVisibility();
      var next = document.querySelector('[data-sla-tracker-tab]');
      if (next) { activateTracker(next.getAttribute('data-sla-tracker-tab')); }
    }).fail(function (xhr) {
      window.alert((xhr.responseJSON || {}).error || 'Unable to remove tracker');
    });
  }

  function openCloneTrackerModal() {
    var button = byId('sla-clone-tracker-button');
    var source = byId('sla-clone-tracker-source');
    var modal = byId('sla-clone-tracker-modal');
    var targetTab = document.querySelector('[data-sla-tracker-tab="' + state.tracker + '"]');
    if (!button || !source || !modal || !source.value || !targetTab || source.value === state.tracker) { return; }
    var sourceName = source.options[source.selectedIndex].textContent;
    var targetName = targetTab.getAttribute('data-tracker-name');
    modal.setAttribute('data-source-id', source.value);
    modal.setAttribute('data-target-id', state.tracker);
    modal.querySelector('#sla-clone-tracker-title').textContent =
      modal.getAttribute('data-title-template').replace('%{tracker}', targetName);
    modal.querySelector('[data-sla-clone-tracker-message]').textContent =
      modal.getAttribute('data-confirm-template').replace('%{source}', sourceName).replace('%{target}', targetName);
    modal.classList.remove('hidden');
    modal.querySelector('[data-sla-clone-tracker-confirm]').focus();
  }

  function closeCloneTrackerModal() {
    var modal = byId('sla-clone-tracker-modal');
    if (modal) { modal.classList.add('hidden'); }
  }

  function cloneTrackerTargets() {
    var button = byId('sla-clone-tracker-button');
    var modal = byId('sla-clone-tracker-modal');
    if (!button || !modal) { return; }
    var confirmButton = modal.querySelector('[data-sla-clone-tracker-confirm]');
    if (confirmButton) { confirmButton.disabled = true; }
    jQuery.ajax({
      url: button.getAttribute('data-endpoint'), method: 'PATCH', dataType: 'json',
      headers: csrfHeaders(),
      data: { source_tracker_id: modal.getAttribute('data-source-id'),
              target_tracker_id: modal.getAttribute('data-target-id') }
    }).done(function () {
      window.location.reload();
    }).fail(function (xhr) {
      var response = xhr.responseJSON || {};
      window.alert(response.error || 'Unable to clone tracker targets');
      if (confirmButton) { confirmButton.disabled = false; }
    });
  }

  function targetParts(cell) {
    return {
      editor: cell.querySelector('[data-sla-target-editor]'),
      display: cell.querySelector('[data-sla-target-display]'),
      value: cell.querySelector('[data-sla-target-value]'),
      unit: cell.querySelector('[data-sla-target-unit]'),
      bestEffort: cell.querySelector('[data-sla-target-best-effort]'),
      status: cell.querySelector('[data-sla-target-status]')
    };
  }

  function syncTargetInputs(cell) {
    var parts = targetParts(cell);
    var disabled = parts.bestEffort.checked;
    parts.value.disabled = disabled;
    parts.unit.disabled = disabled;
    if (parts.unit.tomselect) {
      if (disabled) { parts.unit.tomselect.disable(); } else { parts.unit.tomselect.enable(); }
    }
  }

  function targetValueIsValid(cell, showWarning) {
    var parts = targetParts(cell);
    var raw = parts.value.value.trim();
    var valid = parts.bestEffort.checked || raw === '' ||
      (!parts.value.validity.badInput && /^\d+$/.test(raw) && Number(raw) > 0);

    if (!valid && showWarning) {
      parts.status.textContent = cell.getAttribute('data-whole-number-error');
      parts.status.className = 'tw-mt-1 tw-block tw-text-xs tw-text-red-600';
    } else if (valid && parts.status.classList.contains('tw-text-red-600')) {
      parts.status.textContent = '';
      parts.status.className = 'tw-mt-1 tw-block tw-text-xs';
    }
    return valid;
  }

  function showWholeNumberWarning(cell) {
    var parts = targetParts(cell);
    parts.status.textContent = cell.getAttribute('data-whole-number-error');
    parts.status.className = 'tw-mt-1 tw-block tw-text-xs tw-text-red-600';
  }

  function syncRecalculateButton() {
    var button = document.querySelector('[data-sla-recalculate-button]');
    var checkbox = document.querySelector('input[name="recalculate"]');
    if (!button || !checkbox) { return; }
    button.disabled = !checkbox.checked;
  }

  function saveTargetCell(cell) {
    var parts = targetParts(cell);
    if (!targetValueIsValid(cell, true)) {
      parts.editor.classList.remove('hidden');
      return;
    }
    var mode = parts.bestEffort.checked ? 'best_effort' :
      (parts.value.value.trim() ? 'duration' : 'unset');
    var token = document.querySelector('meta[name="csrf-token"]');
    parts.status.textContent = '';

    jQuery.ajax({
      url: cell.getAttribute('data-endpoint'),
      method: 'PATCH',
      dataType: 'json',
      headers: token ? { 'X-CSRF-Token': token.content } : {},
      data: {
        tracker_id: cell.getAttribute('data-tracker-id'),
        priority_id: cell.getAttribute('data-priority-id'),
        target_type: cell.getAttribute('data-target-type'),
        mode: mode,
        value: parts.value.value,
        unit: parts.unit.value
      }
    }).done(function (response) {
      cell.setAttribute('data-seconds', response.seconds || '');
      cell.setAttribute('data-best-effort', response.best_effort ? 'true' : 'false');
      parts.display.textContent = response.display;
      parts.status.textContent = response.message;
      parts.status.className = 'tw-mt-1 tw-block tw-text-xs tw-text-green-600';
      if (response.recalculation) {
        startRecalculationPolling(response.recalculation.run_token);
      }
    }).fail(function (xhr) {
      var response = xhr.responseJSON || {};
      parts.status.textContent = response.error || 'Unable to save';
      parts.status.className = 'tw-mt-1 tw-block tw-text-xs tw-text-red-600';
    });
  }

  // A switch marked data-sla-reveals="<key>" owns the [data-sla-reveal="<key>"] block of detail
  // fields below it: an alert card the project doesn't use stays a single line. The block is only
  // HIDDEN, never emptied — its inputs still post, so switching an alert off and on again cannot
  // silently drop the recipients already saved for it.
  function syncReveals() {
    document.querySelectorAll('[data-sla-reveals]').forEach(function (input) {
      var key = input.getAttribute('data-sla-reveals');
      var block = document.querySelector('[data-sla-reveal="' + key + '"]');
      if (block) { block.classList.toggle('hidden', !input.checked); }
    });
  }

  // --- SLA tracking off => the configuration sections are locked ------------------------------
  // Server-rendered on load (SlaPoliciesHelper#sla_tracking_off?). Mirrored here so flipping the
  // General switch locks or unlocks SLA Targets, Measurement Rules and Notifications
  // straight away, instead of the page claiming they are editable until a save lands. Nothing here
  // decides anything the server doesn't re-decide on save — it only stops the UI from lying between
  // the flip and the save.

  // What the General section's on/off control currently reads. Inheriting projects use the same
  // visual switch as self-defining projects, but post a lightweight enablement decision instead
  // of changing any inherited configuration.
  function trackingOn() {
    var inheritedToggle = document.querySelector('[data-sla-inherited-enablement]');
    if (inheritedToggle) { return inheritedToggle.checked; }

    var toggle = document.querySelector('input[type="checkbox"][name="sla_policy[enabled]"]');
    // No control on the page at all (a notifications-only manager): trust what the server rendered.
    return toggle ? toggle.checked : !document.querySelector('fieldset[data-sla-lock][disabled]');
  }

  function syncLocks() {
    var locked = !trackingOn();

    document.querySelectorAll('fieldset[data-sla-lock]').forEach(function (fieldset) {
      fieldset.disabled = locked;
      // A Tom Select control is a div, not the original <select>, so being inside a disabled
      // fieldset doesn't stop it responding to clicks — its own API has to be told. (Its <select>
      // is still what posts, so the data is safe either way; this is about not offering a control
      // that will be ignored.)
      fieldset.querySelectorAll('select').forEach(function (select) {
        if (!select.tomselect) { return; }
        if (locked) { select.tomselect.disable(); } else { select.tomselect.enable(); }
      });
    });

    document.querySelectorAll('[data-sla-locked-notice]').forEach(function (notice) {
      notice.classList.toggle('hidden', !locked);
    });
    // The attribute is on every nav row, true or false (see _nav.html.erb) — match on the value.
    document.querySelectorAll('[data-sla-lockable="true"]').forEach(function (link) {
      link.classList.toggle('is-locked', locked);
    });
  }

  function saveTracking(input) {
    var container = input.closest('#sla-general-form, #sla-enablement-form');
    if (!container) { return; }

    input.disabled = true;
    var inherited = input.hasAttribute('data-sla-inherited-enablement');
    var data = inherited ? { enablement: input.checked ? 'enabled' : 'disabled' } :
      { enabled: input.checked ? '1' : '0' };
    jQuery.ajax({
      url: container.getAttribute('data-tracking-url'),
      method: 'PATCH',
      dataType: 'json',
      headers: csrfHeaders(),
      data: data
    }).done(function () {
      window.location.reload();
    }).fail(function (xhr) {
      input.checked = input.getAttribute('data-sla-saved-checked') === 'true';
      input.disabled = false;
      syncLocks();
      window.alert((xhr.responseJSON || {}).error || 'Unable to save SLA Tracking');
    });
  }

  function snapshotTrackingToggle() {
    var input = document.querySelector(
      'input[type="checkbox"][name="sla_policy[enabled]"], [data-sla-inherited-enablement]'
    );
    if (input) { input.setAttribute('data-sla-saved-checked', input.checked ? 'true' : 'false'); }
  }

  function openRevertPolicyModal() {
    var modal = byId('sla-revert-policy-modal');
    if (!modal) { return; }
    state.revertTrigger = this;
    modal.classList.remove('hidden');
    modal.setAttribute('aria-hidden', 'false');
    var cancel = modal.querySelector('button[data-sla-revert-cancel]');
    if (cancel) { cancel.focus(); }
  }

  function closeRevertPolicyModal() {
    var modal = byId('sla-revert-policy-modal');
    if (!modal || modal.classList.contains('hidden')) { return; }
    modal.classList.add('hidden');
    modal.setAttribute('aria-hidden', 'true');
    if (state.revertTrigger) { state.revertTrigger.focus(); }
    state.revertTrigger = null;
  }

  function measurementStatus(message, failed) {
    var status = document.querySelector('[data-sla-measurement-status]');
    if (!status) { return; }
    status.textContent = message;
    status.className = 'tw-mt-1 tw-text-right tw-text-xs ' +
      (failed ? 'tw-text-red-600' : 'tw-text-green-600');
  }

  function saveMeasurement(input) {
    var container = byId('sla-measurement-form');
    if (!container) { return; }
    var role = input.getAttribute('data-sla-measurement-role');
    var attribute = input.getAttribute('data-sla-measurement-attribute');
    if (!role && !attribute) { return; }

    var data = role ? {
      role: role,
      status_ids: Array.prototype.map.call(input.selectedOptions, function (option) {
        return option.value;
      })
    } : { attribute: attribute, value: input.value };

    measurementStatus('Saving…', false);
    jQuery.ajax({
      url: container.getAttribute('data-measurement-url'),
      method: 'PATCH',
      dataType: 'json',
      headers: csrfHeaders(),
      data: data
    }).done(function (response) {
      measurementStatus(response.message || 'Saved', false);
    }).fail(function (xhr) {
      measurementStatus((xhr.responseJSON || {}).error || 'Unable to save', true);
    });
  }

  function toggleDigestInterval() {
    var field = byId('sla-digest-interval-field');
    if (!field) { return; }
    var checked = document.querySelector(
      'input[name="sla_notification_setting[at_risk_email_frequency]"]:checked'
    );
    field.classList.toggle('hidden', !(checked && checked.value === 'digest'));
  }

  function notificationStatus(form, message, failed) {
    var status = form.querySelector('[data-sla-notification-status]');
    if (!status) { return; }
    status.textContent = message;
    status.className = 'tw-mt-1 tw-text-right tw-text-xs ' +
      (failed ? 'tw-text-red-600' : 'tw-text-green-600');
  }

  // Persist exactly one notification control at a time. All elements sharing the changed
  // control's name are serialized together: Rails checkbox hidden+visible pairs, radio groups,
  // and multi-select hidden+selected values therefore retain their native parameter semantics.
  // No sibling field is posted, so overlapping responses cannot revert a newer edit elsewhere.
  function saveNotification(input) {
    var form = input.closest('[data-sla-notification-autosave]');
    if (!form || !input.name) { return; }

    var sameName = Array.prototype.filter.call(form.elements, function (element) {
      return element.name === input.name;
    });
    var methodOverride = form.querySelector('input[name="_method"]');

    notificationStatus(form, 'Saving…', false);
    jQuery.ajax({
      url: form.action,
      method: methodOverride ? methodOverride.value.toUpperCase() : form.method.toUpperCase(),
      dataType: 'json',
      headers: csrfHeaders(),
      data: jQuery(sameName).serialize()
    }).done(function (response) {
      notificationStatus(form, response.message || 'Saved', false);
    }).fail(function (xhr) {
      notificationStatus(form, (xhr.responseJSON || {}).error || 'Unable to save', true);
    });
  }

  function openCloneConfirmation() {
    var source = byId('sla-clone-source');
    var modal = byId('sla-clone-confirm-modal');
    if (!source || !source.value || !modal) { return; }
    var selected = source.options[source.selectedIndex];
    modal.setAttribute('data-source-id', source.value);
    modal.setAttribute('data-source-name', selected ? selected.textContent : '');
    modal.querySelector('[data-sla-clone-confirm-message]').textContent =
      modal.getAttribute('data-confirm-template').replace(
        '%{project}', selected ? selected.textContent : ''
      );
    modal.classList.remove('hidden');
    modal.querySelector('[data-sla-clone-confirm]').focus();
  }

  function closeCloneConfirmation() {
    var modal = byId('sla-clone-confirm-modal');
    if (modal) { modal.classList.add('hidden'); }
  }

  function loadClonePolicy() {
    var modal = byId('sla-clone-confirm-modal');
    var form = byId('sla-policy-form');
    if (!modal || !form) { return; }
    var confirmButton = modal.querySelector('[data-sla-clone-confirm]');
    if (confirmButton) { confirmButton.disabled = true; }

    jQuery.ajax({
      url: form.getAttribute('data-policy-url'),
      method: 'PUT',
      dataType: 'json',
      headers: csrfHeaders(),
      data: { section: 'targets', tab: 'sla_policy',
              clone_source_id: modal.getAttribute('data-source-id') }
    }).done(function () {
      window.location.reload();
    }).fail(function (xhr) {
      if (confirmButton) { confirmButton.disabled = false; }
      window.alert((xhr.responseJSON || {}).error || 'Unable to load policy');
    });
  }

  function bindOnce() {
    if (state.bound) { return; }
    state.bound = true;

    jQuery(document).on('click', '[data-sla-section-link]', function (event) {
      event.preventDefault();
      activateSection(this.getAttribute('data-sla-section-link'));
    });

    // The locked banner's "General" link is NOT a nav item, so it gets its own attribute and its
    // own handler: the sidebar handler marks every [data-sla-section-link] it finds active or
    // inactive, and this link has no business being in that set.
    jQuery(document).on('click', '[data-sla-goto-section]', function (event) {
      event.preventDefault();
      activateSection(this.getAttribute('data-sla-goto-section'));
    });

    jQuery(document).on('change',
      'input[name="sla_policy[enabled]"], input[name="sla_policy[enablement]"]', function () {
        syncLocks();
        saveTracking(this);
      });

    jQuery(document).on('click', '[data-sla-revert-open]', openRevertPolicyModal);
    jQuery(document).on('click', '[data-sla-revert-cancel]', closeRevertPolicyModal);

    jQuery(document).on('change',
      '[data-sla-measurement-role], [data-sla-measurement-attribute]', function () {
        saveMeasurement(this);
      });

    jQuery(document).on('change', '[data-sla-reveals]', syncReveals);
    jQuery(document).on('change', '[data-sla-notification-field]', function () {
      saveNotification(this);
    });
    jQuery(document).on('change',
      'input[name="sla_notification_setting[at_risk_email_frequency]"]', toggleDigestInterval);

    jQuery(document).on('change', '#sla-definitions-trackers', function () {
      syncDefinitionTables(this);
    });
    jQuery(document).on('click', '[data-sla-tracker-tab]', function () {
      activateTracker(this.getAttribute('data-sla-tracker-tab'));
    });
    jQuery(document).on('click', '[data-sla-add-tracker-toggle]', openAddTrackerMenu);
    jQuery(document).on('click', '[data-sla-add-tracker-close]', closeAddTrackerMenu);
    jQuery(document).on('click', '[data-sla-add-tracker]', function () { addTracker(this); });
    jQuery(document).on('click', '[data-sla-remove-tracker]', function (event) {
      event.preventDefault();
      event.stopPropagation();
      openRemoveTrackerModal(this.parentNode.querySelector('[data-sla-tracker-tab]'));
    });
    jQuery(document).on('click', '[data-sla-remove-cancel]', closeRemoveTrackerModal);
    jQuery(document).on('click', '[data-sla-remove-confirm]', removeTracker);
    jQuery(document).on('keydown', function (event) {
      if (event.key === 'Escape') {
        closeAddTrackerMenu();
        closeRemoveTrackerModal();
        closeCloneConfirmation();
        closeCloneTrackerModal();
        closeRevertPolicyModal();
      }
    });
    jQuery(document).on('click', '#sla-clone-tracker-button', openCloneTrackerModal);
    jQuery(document).on('click', '[data-sla-clone-tracker-cancel]', closeCloneTrackerModal);
    jQuery(document).on('click', '[data-sla-clone-tracker-confirm]', cloneTrackerTargets);

    jQuery(document).on('click', '[data-sla-target-display]', function () {
      var cell = this.closest('[data-sla-target-cell]');
      targetParts(cell).editor.classList.remove('hidden');
      syncTargetInputs(cell);
      if (!targetParts(cell).bestEffort.checked) { targetParts(cell).value.focus(); }
    });
    jQuery(document).on('change', '[data-sla-target-best-effort]', function () {
      var cell = this.closest('[data-sla-target-cell]');
      syncTargetInputs(cell);
      targetValueIsValid(cell, false);
    });
    jQuery(document).on('input', '[data-sla-target-value]', function () {
      targetValueIsValid(this.closest('[data-sla-target-cell]'), true);
    });
    jQuery(document).on('keydown', '[data-sla-target-value]', function (event) {
      if (event.key === '.' || event.key === ',' || event.key.toLowerCase() === 'e') {
        event.preventDefault();
        showWholeNumberWarning(this.closest('[data-sla-target-cell]'));
      }
    });
    jQuery(document).on('change', 'input[name="recalculate"]', syncRecalculateButton);
    jQuery(document).on('click', '[data-sla-recalculate-button]', runHistoricalRecalculation);
    jQuery(document).on('focusout', '[data-sla-target-editor]', function () {
      var editor = this;
      window.setTimeout(function () {
        if (editor.contains(document.activeElement)) { return; }
        editor.classList.add('hidden');
        saveTargetCell(editor.closest('[data-sla-target-cell]'));
      }, 0);
    });
    jQuery(document).on('keydown', '[data-sla-target-editor]', function (event) {
      if (event.key !== 'Enter') { return; }
      event.preventDefault();
      this.classList.add('hidden');
      saveTargetCell(this.closest('[data-sla-target-cell]'));
    });

    jQuery(document).on('click', '#sla-clone-load', function () {
      openCloneConfirmation();
    });
    jQuery(document).on('click', '[data-sla-clone-cancel]', closeCloneConfirmation);
    jQuery(document).on('click', '[data-sla-clone-confirm]', loadClonePolicy);
  }

  function init() {
    if (!byId('sla-policy-settings') &&
        !document.querySelector('[data-sla-notification-autosave]')) {
      return;
    }
    // Re-assert the open section after an AJAX re-render replaced the nav and panels. The DOM —
    // not the previously open section — is authoritative here: the response decides which panels
    // exist, and honouring a stale value could hide every one it just built.
    state.section = '';
    activateSection(domSection());
    initChips();
    initEmailChips();
    initSingleSelects();
    renderTrackerTabs(byId('sla-definitions-trackers'));
    syncTrackerManagerVisibility();
    // After the Tom Select instances exist, so a section rendered locked disables them too.
    snapshotTrackingToggle();
    syncLocks();
    syncReveals();
    toggleDigestInterval();
    syncRecalculateButton();
    pollRecalculationProgress();
    bindOnce();
  }

  window.slaPolicyForm = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
