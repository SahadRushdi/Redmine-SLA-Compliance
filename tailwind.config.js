/** @type {import('tailwindcss').Config} */
// Scoped build so the plugin's Tailwind/Flowbite CSS cannot leak into or break Redmine's UI:
//   - prefix 'tw-'        : every utility is namespaced (tw-flex, tw-text-sm, ...)
//   - preflight disabled  : no global reset (Preflight is the #1 cause of "my plugin broke Redmine")
//   - .sla-plugin scoping : applied in postcss.config.js via postcss-prefix-selector, which wraps
//                           EVERY selector (including Flowbite's plugin-injected global form/base
//                           styles that Tailwind's `important` option would NOT scope) under
//                           `.sla-plugin`. That is the real guard against bleed into Redmine forms.
module.exports = {
  prefix: 'tw-',
  corePlugins: {
    preflight: false,
  },
  content: [
    './app/views/**/*.html.erb',
    './app/helpers/**/*.rb',
    './assets/javascripts/**/*.js',
    './node_modules/flowbite/**/*.js',
  ],
  theme: {
    extend: {
      // Primary UI colour is blue (Global Rule 7).
      colors: {
        primary: {
          50: '#eff6ff',
          100: '#dbeafe',
          200: '#bfdbfe',
          300: '#93c5fd',
          400: '#60a5fa',
          500: '#3b82f6',
          600: '#2563eb',
          700: '#1d4ed8',
          800: '#1e40af',
          900: '#1e3a8a',
        },
      },
    },
  },
  plugins: [
    require('flowbite/plugin'),
  ],
};
