/**
 * Tailwind config for the SwiftBot landing page (Website/public/index.html).
 * Brand palette is borrowed from the SwiftBot app Web UI (Apple blue + Discord
 * blurple + cyan) so the marketing site matches the product.
 *
 * Rebuild the static stylesheet (from the repo root) after editing index.html classes:
 *   npx tailwindcss@3 -c Website/tailwind.config.js \
 *     -i Website/styles/tailwind.src.css \
 *     -o Website/public/assets/css/tailwind.css --minify
 */
module.exports = {
  darkMode: 'class',
  content: ['./public/index.html', './public/help/**/*.html'],
  theme: {
    extend: {
      colors: {
        brand: {
          dark: '#0a0c14',
          purple: '#5865f2',   // Discord blurple (primary accent)
          violet: '#237cff',   // Web UI blue
          cyan: '#64d2ff',     // Web UI cyan
          magenta: '#45b4ff',  // bright blue accent
          accent: '#64d2ff',
          border: 'rgba(255, 255, 255, 0.08)'
        }
      },
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', 'SF Pro Text', 'Segoe UI', 'Roboto', 'Helvetica Neue', 'Arial', 'sans-serif'],
        display: ['-apple-system', 'BlinkMacSystemFont', 'SF Pro Display', 'Segoe UI', 'Roboto', 'Helvetica Neue', 'Arial', 'sans-serif'],
      }
    }
  }
}
