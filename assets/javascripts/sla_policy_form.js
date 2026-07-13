/* SLA policy settings-tab behaviour (Phase 4). Loaded only on the Project Settings page.
 * init() is idempotent and re-invoked from edit.js.erb after AJAX re-renders; event handlers
 * are delegated (bound once) so replaced DOM keeps working. Config strings/URLs come from
 * data- attributes on #sla-policy-form — no ERB in this asset. */
(function () {
  'use strict';

  var state = { defsSnapshot: '', prevTracker: '', bound: false };

  function byId(id) { return document.getElementById(id); }

  function formData(key) {
    var form = byId('sla-policy-form');
    return form ? form.getAttribute('data-' + key) : null;
  }

  function initChips() {
    document.querySelectorAll('select[data-sla-chips]').forEach(function (el) {
      if (!el.tomselect && window.TomSelect) {
        new TomSelect(el, { plugins: ['remove_button'] });
      }
    });
  }

  function initEmailChips() {
    document.querySelectorAll('select[data-sla-emails]').forEach(function (el) {
      if (!el.tomselect && window.TomSelect) {
        new TomSelect(el, {
          plugins: ['remove_button'],
          create: true,
          persist: false,
          createFilter: function (input) { return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(input); }
        });
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

  function toggleDigestInterval() {
    var field = byId('sla-digest-interval-field');
    if (!field) { return; }
    var checked = document.querySelector(
      'input[name="sla_notification_setting[at_risk_email_frequency]"]:checked'
    );
    field.classList.toggle('hidden', !(checked && checked.value === 'digest'));
  }

  function fetchRerender(params) {
    return jQuery.ajax({ url: formData('edit-url'), data: params, dataType: 'script' });
  }

  function bindOnce() {
    if (state.bound) { return; }
    state.bound = true;

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
  }

  function init() {
    if (!byId('sla-policy-form') && !byId('sla-notification-form')) { return; }
    initChips();
    initEmailChips();
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
