// Build pipeline for the scoped plugin stylesheet.
//
// Order matters:
//   1. tailwindcss           — generate utilities + Flowbite plugin's component/base CSS
//   2. postcss-prefix-selector — wrap EVERY selector under `.sla-plugin` so nothing (not even
//                                Flowbite's global `input`/`[type=checkbox]`/`::file-selector-button`
//                                base styles) can leak into Redmine's own markup
//   3. autoprefixer          — vendor prefixes
module.exports = {
  plugins: [
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
