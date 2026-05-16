# SwiftBot Admin UI

Vite + React + TypeScript + Tailwind source for the SwiftBot admin panel.

## Workflow

```bash
cd admin-ui
npm install
npm run dev      # local dev at http://localhost:5173 (proxies /api, /v1, /auth to :8090)
npm run build    # outputs to ../SwiftBotApp/Resources/admin/{index.html, assets/}
```

The built `index.html` + `assets/*.js` + `assets/*.css` are committed to the
repo so the Xcode build doesn't depend on Node. After running `npm run build`,
commit the changes under `SwiftBotApp/Resources/admin/`.

`AdminWebServer.swift` serves these static files at `/` and `/assets/*`.

## Original UI

The previous hand-written `index.html` (pre-React) is preserved in git history.
