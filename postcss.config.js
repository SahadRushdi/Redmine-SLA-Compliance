// Build pipeline for the scoped plugin stylesheet.
//
// Order matters:
//   1. postcss-import        — inline @import'd vendor CSS (Step 6.1: flowbite-datepicker's own
//                                stylesheet, pulled in from tailwind.input.css) BEFORE scoping
//                                runs, so it gets the exact same .sla-plugin treatment as
//                                everything else. This matters: flowbite-datepicker's CSS ships
//                                its own Tailwind-Preflight-style universal reset
//                                (`*, ::before, ::after { ... }`) — loading that raw/unscoped
//                                (the way tom-select.min.css is plain-copied) would silently
//                                apply a global box-sizing/border/margin reset to every element
//                                on every Redmine page. Routing it through this pipeline instead
//                                turns that into `.sla-plugin *, .sla-plugin ::before, ...`.
//   2. tailwindcss           — generate utilities + Flowbite plugin's component/base CSS
//   3. postcss-prefix-selector — wrap EVERY selector under `.sla-plugin` so nothing (not even
//                                Flowbite's global `input`/`[type=checkbox]`/`::file-selector-button`
//                                base styles) can leak into Redmine's own markup
//   4. autoprefixer          — vendor prefixes
module.exports = {
  plugins: [
    require('postcss-import'),
    require('tailwindcss'),
    require('postcss-prefix-selector')({
      prefix: '.sla-plugin',
      transform(prefix, selector, prefixedSelector) {
        // Already scoped (e.g. our own `.sla-plugin ...` rules): leave as-is, no double prefix.
        if (selector.includes('.sla-plugin')) return selector;
        // Root/document selectors can't be nested under a class and never match Redmine chrome;
        // remap them onto the wrapper so any CSS custom properties still resolve inside the plugin.
        if (selector === ':root' || selector === 'html' || selector === 'body') return prefix;
        return prefixedSelector;
      },
    }),
    require('autoprefixer'),
  ],
};
