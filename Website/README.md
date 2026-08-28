# SwiftBot Website

This folder contains the production website published at
[swiftbot.dev](https://swiftbot.dev).

## Structure

- `public/` is the static site deployed to GitHub Pages.
- `../docs/appcast.xml` is the live stable Sparkle feed, managed by ShipHook,
  and is what `SUFeedURL` resolves to. `../docs/release-notes/` holds the notes
  for ShipHook-published versions. Deployment overlays `docs/` onto `public/`,
  so the docs copy wins when both exist — which is why there is deliberately no
  `public/appcast.xml`.
- `public/beta/appcast.xml` is the live beta feed (currently an empty channel).
  `docs/` has no beta counterpart, so this file is served as-is.
- `public/release-notes/` contains the pre-ShipHook release-note archive
  (versions up to 1.22.5, plus older releases the docs copy does not carry).
- `public/help/` contains the help and knowledge-base pages.
- `styles/` is reserved for stylesheet source files that are not published
  directly (e.g. `tailwind.src.css`).
- `tailwind.config.js` configures the generated Tailwind stylesheet.

## Editing

Most pages are plain HTML, CSS, and JavaScript. After changing Tailwind classes,
rebuild the generated stylesheet from the repository root:

```sh
npx tailwindcss@3 -c Website/tailwind.config.js \
  -i Website/styles/tailwind.src.css \
  -o Website/public/assets/css/tailwind.css --minify
```

> The Tailwind *source* (`Website/styles/tailwind.src.css`) is not currently
> tracked — only the built `public/assets/css/tailwind.css`. Add the source under
> `styles/` if you need to regenerate the stylesheet.

Do not edit appcast version or build fields during ordinary website work.
ShipHook owns those fields. The only manual appcast edit is the documented
post-release EdDSA signature step.

## Deployment

`.github/workflows/deploy-website.yml` overlays `docs/` release metadata onto
`Website/public/`, then uploads that merged folder as the GitHub Pages artifact
whenever website or docs files change on `main`. The published folder becomes
the domain root, so public URLs remain `/appcast.xml`, `/help/`, and
`/release-notes/`.
