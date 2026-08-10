/* SLA policy settings-tab behaviour (Phase 4). Loaded only on the Project Settings page.
 * init() is idempotent and re-invoked from edit.js.erb after AJAX re-renders; event handlers
 * are delegated (bound once) so replaced DOM keeps working. Config strings/URLs come from
 * data- attributes on #sla-policy-form — no ERB in this asset. */
(function () {
  'use strict';

  var state = { bound: false, section: '' };

  function byId(id) { return document.getElementById(id); }

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

  function formData(key) {
    var form = byId('sla-policy-form');
    return form ? form.getAttribute('data-' + key) : null;
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
        bindDropUp(new TomSelect(el, { plugins: ['remove_button'] }));
      }
    });
  }

  function initEmailChips() {
    document.querySelectorAll('select[data-sla-emails]').forEach(function (el) {
      if (!el.tomselect && window.TomSelect) {
        bindDropUp(new TomSelect(el, {
          plugins: ['remove_button'],
          create: true,
          persist: false,
          createFilter: function (input) { return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(input); }
        }));
      }
    });
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
      jQuery.ajax({
        url: select.getAttribute('data-table-url'),
        data: { tracker_id: trackerId, section: currentSection() },
        dataType: 'script'
      });
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

  function saveTargetCell(cell) {
    var parts = targetParts(cell);
    var mode = parts.bestEffort.checked ? 'best_effort' :
      (parts.value.value.trim() ? 'duration' : 'unset');
    var token = document.querySelector('meta[name="csrf-token"]');
    var recalculate = document.querySelector('input[name="recalculate"]');
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
        unit: parts.unit.value,
        recalculate: recalculate && recalculate.checked ? '1' : '0'
      }
    }).done(function (response) {
      cell.setAttribute('data-seconds', response.seconds || '');
      cell.setAttribute('data-best-effort', response.best_effort ? 'true' : 'false');
      parts.display.textContent = response.display;
      parts.status.textContent = response.message;
      parts.status.className = 'tw-mt-1 tw-block tw-text-xs tw-text-green-600';
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
  // General switch locks or unlocks SLA Targets, Measurement Rules, Exclusions and Notifications
  // straight away, instead of the page claiming they are editable until a save lands. Nothing here
  // decides anything the server doesn't re-decide on save — it only stops the UI from lying between
  // the flip and the save.

  // What the General section's on/off control currently READS, by whichever of its two forms is on
  // screen: the tri-state radios for an inheriting project, otherwise the plain switch.
  function trackingOn() {
    var picked = document.querySelector('input[name="sla_policy[enablement]"]:checked');
    if (picked) {
      if (picked.value !== 'inherit') { return picked.value === 'enabled'; }
      // "Inherit" resolves against the ancestor's decision, which only the server knows.
      var form = byId('sla-enablement-form');
      return !!form && form.getAttribute('data-inherited-on') === 'true';
    }

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

  function toggleDigestInterval() {
    var field = byId('sla-digest-interval-field');
    if (!field) { return; }
    var checked = document.querySelector(
      'input[name="sla_notification_setting[at_risk_email_frequency]"]:checked'
    );
    field.classList.toggle('hidden', !(checked && checked.value === 'digest'));
  }

  function fetchRerender(params) {
    // The re-render rebuilds the panels server-side, so it has to be told which one to show.
    params.section = currentSection();
    return jQuery.ajax({ url: formData('edit-url'), data: params, dataType: 'script' });
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
      'input[name="sla_policy[enabled]"], input[name="sla_policy[enablement]"]', syncLocks);

    jQuery(document).on('change', '[data-sla-reveals]', syncReveals);
    jQuery(document).on('change',
      'input[name="sla_notification_setting[at_risk_email_frequency]"]', toggleDigestInterval);

    jQuery(document).on('change', '#sla-definitions-trackers', function () {
      syncDefinitionTables(this);
    });

    jQuery(document).on('click', '[data-sla-target-display]', function () {
      var cell = this.closest('[data-sla-target-cell]');
      targetParts(cell).editor.classList.remove('hidden');
      syncTargetInputs(cell);
      if (!targetParts(cell).bestEffort.checked) { targetParts(cell).value.focus(); }
    });
    jQuery(document).on('change', '[data-sla-target-best-effort]', function () {
      syncTargetInputs(this.closest('[data-sla-target-cell]'));
    });
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
      var source = byId('sla-clone-source');
      if (!source || !source.value) { return; }
      if (!window.confirm(formData('confirm-clone'))) { return; }
      fetchRerender({ clone_from: source.value });
    });
  }

  function init() {
    if (!byId('sla-policy-settings') && !byId('sla-notification-form')) {
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
    // After the Tom Select instances exist, so a section rendered locked disables them too.
    syncLocks();
    syncReveals();
    toggleDigestInterval();
    bindOnce();
  }

  window.slaPolicyForm = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
