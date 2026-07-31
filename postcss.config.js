// Build pipeline for the scoped plugin stylesheet.
//
// Order matters:
//   1. postcss-import        — inline this plugin's own @import'd partials (assets/stylesheets/
//                                partials/*.css, pulled in from tailwind.input.css) BEFORE scoping
//                                runs, so every rule in them gets the exact same .sla-plugin
//                                treatment as everything else, rather than staying as separate
//                                unscoped @import statements in the compiled output.
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
