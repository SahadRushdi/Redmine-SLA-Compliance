/* SLA policy settings-tab behaviour (Phase 4). Loaded only on the Project Settings page.
 * init() is idempotent and re-invoked from edit.js.erb after AJAX re-renders; event handlers
 * are delegated (bound once) so replaced DOM keeps working. Config strings/URLs come from
 * data- attributes on #sla-policy-form — no ERB in this asset. */
(function () {
  'use strict';

  var state = { defsSnapshot: '', prevTracker: '', bound: false, section: '' };

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

  // Single-value dropdowns (Coverage hours, Business calendar, Tracker, target durations,
  // stale-digest frequency). Native <select> popups are OS/browser-chrome-rendered and can't be
  // themed to match the rest of the scoped Flowbite UI — Tom Select replaces them with the same
  // styled, HTML-rendered dropdown already used for the chip multi-selects (see .ts-dropdown in
  // tailwind.input.css), which also sidesteps the native-select text-clipping some browsers
  // exhibit under Purplemine2's fixed input height. Tom Select keeps the original <select>'s
  // `.value` in sync and re-dispatches `change` on it, so existing handlers (toggleCalendarField,
  // snapshotDefs, the tracker-switch confirm) keep working unmodified.
  function initSingleSelects() {
    document.querySelectorAll('select[data-sla-select]').forEach(function (el) {
      if (!el.tomselect && window.TomSelect) {
        bindDropUp(new TomSelect(el, { create: false, allowEmptyOption: true }));
      }
    });
  }

  function snapshotDefs() {
    var rows = byId('sla-definitions-rows');
    if (!rows) { return ''; }
    return Array.prototype.map.call(rows.querySelectorAll('select'), function (select) {
      return select.name + '=' + select.value;
    }).join('&');
  }

  function toggleCalendarField() {
    var coverage = byId('sla_policy_coverage_hours');
    var field = byId('sla-calendar-field');
    if (!coverage || !field) { return; }
    var businessHours = coverage.value === 'business_hours';
    field.classList.toggle('hidden', !businessHours);
    var calendarSelect = byId('sla_policy_business_calendar_id');
    if (calendarSelect) { calendarSelect.required = businessHours; }
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

    jQuery(document).on('change', '[data-sla-reveals]', syncReveals);
    jQuery(document).on('change', '#sla_policy_coverage_hours', toggleCalendarField);
    jQuery(document).on('change',
      'input[name="sla_notification_setting[at_risk_email_frequency]"]', toggleDigestInterval);

    jQuery(document).on('focusin', '#sla-definitions-tracker', function () {
      state.prevTracker = this.value;
    });
    jQuery(document).on('change', '#sla-definitions-tracker', function () {
      var trackerSelect = this;
      if (snapshotDefs() !== state.defsSnapshot &&
          !window.confirm(formData('confirm-switch'))) {
        trackerSelect.value = state.prevTracker;
        return;
      }
      state.prevTracker = trackerSelect.value;
      fetchRerender({ tracker_id: trackerSelect.value });
    });

    jQuery(document).on('click', '#sla-clone-load', function () {
      var source = byId('sla-clone-source');
      if (!source || !source.value) { return; }
      if (!window.confirm(formData('confirm-clone'))) { return; }
      fetchRerender({ clone_from: source.value });
    });

    // B3 — "Override for this project": the button lives in the read-only inherited-policy
    // banner, OUTSIDE #sla-policy-form (which doesn't exist yet in that state), so its own
    // data- attributes carry the edit URL / confirm text rather than reading from the form.
    jQuery(document).on('click', '#sla-override-load', function () {
      var ancestorId = this.getAttribute('data-ancestor-id');
      var editUrl = this.getAttribute('data-edit-url');
      if (!ancestorId || !editUrl) { return; }
      if (!window.confirm(this.getAttribute('data-confirm-override'))) { return; }
      jQuery.ajax({ url: editUrl, data: { clone_from: ancestorId }, dataType: 'script' });
    });
  }

  function init() {
    // The inherited-policy banner (B3) has neither form but still needs its Override button
    // wired up, so it's part of the same early-return guard as the two real forms.
    if (!byId('sla-policy-settings') && !byId('sla-notification-form') && !byId('sla-override-load')) {
      return;
    }
    // Re-assert the open section after an AJAX re-render replaced the nav and panels. The DOM —
    // not the previously open section — is authoritative here: pressing Override from the
    // inherited banner navigates you from Notifications (the only section offered there) to
    // General, and honouring the stale value would hide every panel the response just built.
    state.section = '';
    activateSection(domSection());
    initChips();
    initEmailChips();
    initSingleSelects();
    syncReveals();
    toggleCalendarField();
    toggleDigestInterval();
    state.defsSnapshot = snapshotDefs();
    var trackerSelect = byId('sla-definitions-tracker');
    state.prevTracker = trackerSelect ? trackerSelect.value : '';
    bindOnce();
  }

  window.slaPolicyForm = { init: init };
  document.addEventListener('DOMContentLoaded', init);
})();
