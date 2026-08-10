  /* Stops the first Tom Select dropdown on a page from hanging open before the user has touched
 * anything.
 *
 * ROOT CAUSE. Redmine core ends application.js with `$(document).ready(defaultFocus)`, and
 * defaultFocus does:
 *
 *     $('#content input[type=text]:visible, #content textarea:visible').first().focus();
 *
 * Harmless for a native <select> — it isn't a text input, so it never matched. But jQuery 3
 * resolves its ready queue in a MICROTASK, after every native DOMContentLoaded listener has run,
 * and this plugin builds its Tom Select instances in exactly such a listener. By the time
 * defaultFocus runs, the first <select> on the page has become a Tom Select, whose control IS an
 * `input[type=text]`. Core focuses it, Tom Select's `openOnFocus` (on by default) fires, and the
 * list is open on arrival — reported on SLA Targets, Measurement Rules and Exclusions, but true of
 * every page in the plugin whose first field is a dropdown.
 *
 * FIX. Start each guarded instance with `openOnFocus` OFF, and turn it on the moment the user
 * first interacts with the document. Before that first pointer or key event, any focus is by
 * definition programmatic, so there is nothing to open a list for; afterwards every instance
 * behaves exactly as stock Tom Select does.
 *
 * The flag is flipped from a CAPTURE-phase listener on the document, which is what makes the very
 * first click on a control still work in one click: our listener runs before Tom Select's own
 * mousedown handler on that control, so by the time it focuses the input, openOnFocus is already
 * back to true and the list opens as the user expects.
 *
 * REJECTED ALTERNATIVE, for whoever reads this next: blurring the control from a capture-phase
 * focus listener. It looks tidier and needs no per-instance call, but Tom Select's own blur
 * handling re-focuses the control, and the two fight — measured at 43 focus events in a row,
 * ending with focus on <body> and the dropdown still open.
 *
 * Loaded from sla_compliance/_assets.html.erb, which every plugin view renders, and whose header
 * tags are emitted ahead of each page's own script — so slaTomSelect exists before any instance is
 * built. Depends on nothing: no jQuery, no TomSelect global.
 */
(function () {
  'use strict';

  var userHasInteracted = false;
  var guarded = [];

  function releaseAll() {
    userHasInteracted = true;
    guarded.forEach(function (instance) {
      if (instance && instance.settings) { instance.settings.openOnFocus = true; }
    });
    guarded = [];
  }

  ['pointerdown', 'mousedown', 'touchstart', 'keydown'].forEach(function (type) {
    document.addEventListener(type, releaseAll, { capture: true, once: true });
  });

  // Call on every Tom Select instance this plugin builds. Returns the instance, so it composes:
  //   slaTomSelect.guard(new TomSelect(el, {...}))
  function guard(instance) {
    if (!instance || !instance.settings || userHasInteracted) { return instance; }

    instance.settings.openOnFocus = false;
    guarded.push(instance);
    return instance;
  }

  window.slaTomSelect = { guard: guard };
})();
