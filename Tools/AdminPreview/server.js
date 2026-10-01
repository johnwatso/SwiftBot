#!/usr/bin/env node
//
// Dev-only preview server for the admin WebUI.
//
// Serves Sources/SwiftBot/Resources/admin/index.html straight from disk and
// answers /api/* with the fixtures in fixtures.js, so admin UI work can be
// checked in a browser without building and running the macOS app.
//
//   node Tools/AdminPreview/server.js        → http://127.0.0.1:4179
//
// Announcer writes are applied to the in-memory fixtures, so add/edit/toggle/
// delete round-trip for the session. Restart to reset. This never touches
// Discord, settings, or anything the real AdminWebServer persists.

const http = require('http');
const fs = require('fs');
const path = require('path');
const fixtures = require('./fixtures');

const ROOT = path.resolve(__dirname, '../../Sources/SwiftBot/Resources/admin');
const PORT = Number(process.env.PORT || 4179);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
  '.woff2': 'font/woff2'
};

// Mutable session copy so the editor's save/toggle/delete round-trip.
let announcer = JSON.parse(JSON.stringify(fixtures.announcer));
let patchy = JSON.parse(JSON.stringify(fixtures.patchy));
let wikibridge = JSON.parse(JSON.stringify(fixtures.wikibridge));
let config = JSON.parse(JSON.stringify(fixtures.config));
let automationRules = JSON.parse(JSON.stringify(fixtures.automationRules));
let welcomeFlow = JSON.parse(JSON.stringify(fixtures.welcomeFlow));
let gametracker = JSON.parse(JSON.stringify(fixtures.gametracker));
let sweep = JSON.parse(JSON.stringify(fixtures.sweep));

function sendJSON(res, body, statusCode = 200) {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      try { resolve(JSON.parse(raw || '{}')); } catch { resolve({}); }
    });
  });
}

// Same idea as RecordingSteamArtworkService: proxy Steam's portrait library
// art so the page only ever loads same-origin images.
const STEAM_APP_IDS = { 'the finals': 2073850, 'apex legends': 1172470, 'helldivers 2': 553850, 'counter-strike 2': 730 };
const posterCache = new Map();
function sendGameArt(res, game) {
  const appID = STEAM_APP_IDS[String(game || '').toLowerCase()];
  // Steam first; Twitch box art by name for games Steam doesn't carry.
  // A 302 from Twitch means its "404_boxart" placeholder, so treat as none.
  const url = appID
    ? `https://cdn.cloudflare.steamstatic.com/steam/apps/${appID}/library_600x900.jpg`
    : `https://static-cdn.jtvnw.net/ttv-boxart/${encodeURIComponent(String(game || ''))}-600x800.jpg`;
  const send = (buf) => { res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'private, max-age=86400' }); res.end(buf); };
  if (posterCache.has(url)) return send(posterCache.get(url));
  require('https').get(url, (up) => {
    if (up.statusCode !== 200) { up.resume(); return sendJSON(res, { error: 'artwork_unavailable' }, 404); }
    const chunks = [];
    up.on('data', c => chunks.push(c));
    up.on('end', () => { const buf = Buffer.concat(chunks); posterCache.set(url, buf); send(buf); });
  }).on('error', () => sendJSON(res, { error: 'artwork_unavailable' }, 404));
}

async function handleAPI(req, res, pathname, query) {
  if (req.method === 'GET') {
    switch (pathname) {
      case '/api/media/game-art': return sendGameArt(res, query.get('game'));
      case '/api/me': return sendJSON(res, fixtures.me);
      case '/api/auth/options': return sendJSON(res, fixtures.authOptions);
      case '/api/overview': return sendJSON(res, fixtures.overview);
      case '/api/status': return sendJSON(res, fixtures.status);
      case '/api/analytics': return sendJSON(res, fixtures.analytics);
      case '/api/rewind': return sendJSON(res, fixtures.rewind);
      case '/api/announcer': return sendJSON(res, announcer);
      case '/api/config': return sendJSON(res, config);
      case '/api/settings': return sendJSON(res, { prefix: fixtures.config.commands.prefix });
      case '/api/commands': return sendJSON(res, fixtures.commands);
      case '/api/automations': {
        const category = query.get('category') || 'automation';
        return sendJSON(res, fixtures.automations(category, automationRules[category]));
      }
      case '/api/welcome-flow': return sendJSON(res, welcomeFlow);
      case '/api/patchy': return sendJSON(res, patchy);
      case '/api/aibots': return sendJSON(res, fixtures.aibots);
      case '/api/wikibridge': return sendJSON(res, wikibridge);
      case '/api/sweep': return sendJSON(res, sweep);
      case '/api/gametracker': return sendJSON(res, gametracker);
      case '/api/media': {
        const game = query.get ? query.get('game') : query.game;
        const range = (query.get ? query.get('dateRange') : query.dateRange) || 'all';
        const days = { '7d': 7, '30d': 30, '90d': 90 }[range];
        const inRange = fixtures.media.items.filter(item => !days || Date.now() - new Date(item.modifiedAt).getTime() < days * 86400000);
        const items = inRange.filter(item => !game || item.gameName === game);
        const gameSummaries = [...new Set(inRange.map(i => i.gameName))].map(name => {
          const entries = inRange.filter(i => i.gameName === name);
          return { name, clipCount: entries.length, latestAt: entries.map(i => i.modifiedAt).sort().pop(), totalBytes: entries.reduce((t, i) => t + i.sizeBytes, 0) };
        }).sort((a, b) => b.latestAt.localeCompare(a.latestAt));
        return sendJSON(res, { ...fixtures.media, items, totalItems: items.length, gameSummaries, games: gameSummaries.map(g => g.name).sort(), selectedGame: game || null, selectedDateRange: range });
      }
      case '/api/media/exports': return sendJSON(res, fixtures.mediaExports);
      case '/api/media/export-status': return sendJSON(res, { installed: true, version: '7.1' });
      default:
        // Everything the announcer work does not exercise (patchy, sweep,
        // media, aibots, …) gets a benign empty payload.
        return sendJSON(res, {});
    }
  }

  if (req.method === 'POST') {
    const body = await readBody(req);

    if (pathname === '/api/announcer/config/upsert') {
      const config = body.config;
      if (!config || !config.id) return sendJSON(res, { ok: false }, 400);
      const index = announcer.configs.findIndex((c) => c.id === config.id);
      if (index >= 0) announcer.configs[index] = config;
      else announcer.configs.push(config);
      console.log(`[upsert] ${config.id}`, JSON.stringify(config, null, 2));
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/announcer/config/toggle') {
      const target = announcer.configs.find((c) => c.id === body.id);
      if (target) target.enabled = !!body.enabled;
      console.log(`[toggle] ${body.id} → ${body.enabled}`);
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/announcer/config/delete') {
      announcer.configs = announcer.configs.filter((c) => c.id !== body.id);
      console.log(`[delete] ${body.id}`);
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/announcer/disconnect') {
      if (!announcer.liveState.isConnected) {
        return sendJSON(res, { error: 'not_connected' }, 400);
      }
      announcer.liveState = {
        ...announcer.liveState,
        isConnected: false,
        connectionLabel: 'Disconnected',
        phaseLabel: 'Idle',
        listening: 'Not listening',
        queueDepth: 0,
        queueLabel: 'No queued announcements',
        manualHold: 'Automatic reconnect paused for 60 min'
      };
      console.log('[disconnect] announcer disconnected, manual hold armed');
      return sendJSON(res, { ok: true });
    }

    if (pathname.startsWith('/api/patchy/')) {
      const find = (id) => patchy.targets.find((t) => t.id === id);
      switch (pathname) {
        case '/api/patchy/state':
          Object.assign(patchy, body);
          break;
        case '/api/patchy/target/new': {
          const target = { ...JSON.parse(JSON.stringify(patchy.targets[0])), id: `preview-${Date.now()}`,
            source: 'Steam', steamAppID: '', lastStatus: 'Never checked', lastCheckedAt: null, lastRunAt: null };
          patchy.targets.push(target);
          console.log('[patchy new]', target.id);
          return sendJSON(res, target);
        }
        case '/api/patchy/target/upsert': {
          // Like the real server: unknown IDs are inserted.
          const index = patchy.targets.findIndex((t) => t.id === body.target?.id);
          if (index < 0) patchy.targets.push(body.target);
          else patchy.targets[index] = body.target;
          console.log('[patchy upsert]', JSON.stringify(body.target, null, 2));
          break;
        }
        case '/api/patchy/target/toggle':
          if (find(body.targetID)) find(body.targetID).isEnabled = !!body.enabled;
          break;
        case '/api/patchy/target/delete':
          patchy.targets = patchy.targets.filter((t) => t.id !== body.targetID);
          break;
        case '/api/patchy/target/pull':
        case '/api/patchy/target/test':
        case '/api/patchy/check': {
          const now = new Date().toISOString();
          (body.targetID ? [find(body.targetID)] : patchy.targets).filter(Boolean).forEach((t) => {
            t.lastCheckedAt = now;
            if (pathname !== '/api/patchy/check') t.lastRunAt = now;
            t.lastStatus = pathname.endsWith('/test') ? 'Delivered test notification' : 'Up to date';
          });
          patchy.lastCycleAt = now;
          break;
        }
      }
      console.log(`[${pathname}]`, JSON.stringify(body));
      return sendJSON(res, { ok: true });
    }

    if (pathname.startsWith('/api/sweep/')) {
      const find = (id) => sweep.policies.find((p) => p.id === id);
      const recount = () => {
        sweep.enabledPolicyCount = sweep.policies.filter((p) => p.isEnabled).length;
        sweep.totalPolicyCount = sweep.policies.length;
      };
      const projection = (policy) => ({ ...JSON.parse(JSON.stringify(sweep.recentReports[0])), id: `preview-${Date.now()}`, policyID: policy.id, policyName: policy.name, dryRun: true, startedAt: new Date().toISOString() });
      switch (pathname) {
        case '/api/sweep/pause':
          sweep.globalPaused = !!body.paused;
          sweep.state = sweep.globalPaused ? 'Paused' : 'Active';
          break;
        case '/api/sweep/policy/update': {
          const index = sweep.policies.findIndex((p) => p.id === body.id);
          if (index < 0) sweep.policies.push(body); else sweep.policies[index] = body;
          console.log('[sweep upsert]', JSON.stringify(body, null, 2));
          recount();
          break;
        }
        case '/api/sweep/policy/delete':
          sweep.policies = sweep.policies.filter((p) => p.id !== body.policyID);
          recount();
          break;
        case '/api/sweep/policy/toggle':
          if (find(body.policyID)) find(body.policyID).isEnabled = !!body.enabled;
          recount();
          break;
        case '/api/sweep/policy/run': {
          const policy = find(body.policyID);
          if (policy) {
            policy.lastRunAt = new Date().toISOString();
            sweep.recentReports.unshift({ ...projection(policy), dryRun: false, id: `run-${Date.now()}` });
          }
          break;
        }
        case '/api/sweep/policy/preview':
          return sendJSON(res, projection(find(body.policyID) || { id: body.policyID, name: 'Rule' }));
        case '/api/sweep/draft/preview':
          return sendJSON(res, projection(body));
        case '/api/sweep/suggestions/scan':
          sweep.lastSuggestionScanAt = new Date().toISOString();
          break;
        case '/api/sweep/suggestions/apply':
        case '/api/sweep/suggestions/dismiss':
          sweep.suggestions = sweep.suggestions.filter((x) => x.id !== body.suggestionID);
          break;
      }
      console.log(`[${pathname}]`, JSON.stringify(body).slice(0, 160));
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/gametracker/update') {
      // Same actions as AdminWebGameTrackerUpdate.
      const players = gametracker.players;
      if (body.action === 'upsertPlayer') {
        const input = body.player;
        const index = players.findIndex((p) => p.id === input.id);
        const channel = gametracker.channels.find((c) => c.id === input.destinationChannelID);
        const next = {
          ...(index >= 0 ? players[index] : { id: `p-${Date.now()}`, score: null, rankName: null, season: null, baselineRecordedAt: null, supportsRankedScore: true }),
          ...input,
          id: index >= 0 ? players[index].id : `p-${Date.now()}`,
          displayName: input.displayName || input.playerID,
          gameDisplayName: 'THE FINALS', providerDisplayName: 'Finals ID',
          destinationChannelName: channel ? channel.name.split('#').pop() : input.destinationChannelID
        };
        if (index >= 0) players[index] = next; else players.push(next);
      } else if (body.action === 'deletePlayer') {
        gametracker.players = players.filter((p) => p.id !== body.playerID);
      } else if (body.action === 'setPlayerEnabled') {
        const player = players.find((p) => p.id === body.playerID);
        if (player) player.isEnabled = !!body.enabled;
      } else if (body.action === 'updateSettings') {
        ['dailyCheckEnabled', 'sessionTrackingEnabled', 'checkHour'].forEach((key) => { if (key in body) gametracker[key] = body[key]; });
        gametracker.enabled = gametracker.dailyCheckEnabled || gametracker.sessionTrackingEnabled;
      }
      gametracker.enabledPlayerCount = gametracker.players.filter((p) => p.isEnabled).length;
      gametracker.totalPlayerCount = gametracker.players.length;
      gametracker.linkedPlayerCount = gametracker.players.filter((p) => p.discordUserID).length;
      console.log('[gametracker]', JSON.stringify(body));
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/welcome-flow') {
      if (body.settings) welcomeFlow.settings = body.settings;
      console.log('[welcome-flow]', JSON.stringify(body.settings));
      return sendJSON(res, { ok: true });
    }

    if (pathname.startsWith('/api/automations/')) {
      const all = () => [...automationRules.automation, ...automationRules.moderation];
      switch (pathname) {
        case '/api/automations/toggle': {
          const target = all().find((r) => r.id === body.id);
          if (target) target.enabled = !target.enabled;
          break;
        }
        case '/api/automations/delete':
          Object.keys(automationRules).forEach((k) => { automationRules[k] = automationRules[k].filter((r) => r.id !== body.id); });
          break;
        case '/api/automations/upsert': {
          const r = body.rule || body;
          const list = automationRules[r.category] || automationRules.automation;
          const index = list.findIndex((x) => x.id === r.id);
          if (index < 0) list.push(r); else list[index] = r;
          console.log('[automation upsert]', JSON.stringify(r, null, 2));
          break;
        }
        case '/api/automations/validate':
          return sendJSON(res, { ok: true, issues: [] });
        case '/api/automations/draft':
          return sendJSON(res, { error: 'Drafting needs Apple Intelligence on the bot.' });
      }
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/commands/toggle') {
      const item = fixtures.commands.items.find(i => i.name === body.name);
      if (!item) return sendJSON(res, { error: 'unknown_command' }, 404);
      item.enabled = !!body.enabled;
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/config') {
      // The Commands page reads these from the command catalog.
      const cmds = fixtures.commands;
      if ('commandsEnabled' in body) cmds.commandsEnabled = !!body.commandsEnabled;
      if ('slashCommandsEnabled' in body) cmds.slashCommandsEnabled = !!body.slashCommandsEnabled;
      if ('musicLinkWatchEnabled' in body) cmds.musicLinkWatch.isEnabled = !!body.musicLinkWatchEnabled;
      if (Array.isArray(body.musicLinkWatchChannelIDs)) cmds.musicLinkWatch.channelIDs = body.musicLinkWatchChannelIDs;
      // Apply the flat patch keys the Settings page sends to the nested config.
      const map = {
        autoStart: ['general', 'autoStart'],
        commandsEnabled: ['commands', 'enabled'],
        slashCommandsEnabled: ['commands', 'slashEnabled'],
        bugTrackingEnabled: ['commands', 'bugTrackingEnabled'],
        swiftMinerEnabled: ['swiftMiner', 'enabled'],
        userTimezones: ['userTimezones', 'mappings']
      };
      Object.entries(body).forEach(([key, value]) => {
        if (map[key]) config[map[key][0]][map[key][1]] = value;
      });
      console.log('[config]', JSON.stringify(body));
      return sendJSON(res, { ok: true });
    }

    if (pathname.startsWith('/api/wikibridge/')) {
      const find = (id) => wikibridge.sources.find((s) => s.id === id);
      switch (pathname) {
        case '/api/wikibridge/state':
          if (typeof body.enabled === 'boolean') wikibridge.enabled = body.enabled;
          break;
        case '/api/wikibridge/source/upsert': {
          const index = wikibridge.sources.findIndex((s) => s.id === body.source?.id);
          if (index < 0) wikibridge.sources.push(body.source);
          else wikibridge.sources[index] = body.source;
          console.log('[wiki upsert]', JSON.stringify(body.source, null, 2));
          break;
        }
        case '/api/wikibridge/source/toggle':
          if (find(body.targetID)) find(body.targetID).enabled = !!body.enabled;
          break;
        case '/api/wikibridge/source/primary':
          wikibridge.sources.forEach((s) => { s.isPrimary = s.id === body.sourceID; });
          break;
        case '/api/wikibridge/source/test':
          if (find(body.sourceID)) Object.assign(find(body.sourceID), { lastStatus: 'OK', lastLookupAt: new Date().toISOString() });
          break;
        case '/api/wikibridge/source/delete':
          wikibridge.sources = wikibridge.sources.filter((s) => s.id !== body.sourceID);
          break;
      }
      console.log(`[${pathname}]`, JSON.stringify(body).slice(0, 200));
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/announcer/settings') {
      Object.assign(announcer, body);
      console.log('[settings]', JSON.stringify(body));
      return sendJSON(res, { ok: true });
    }

    return sendJSON(res, { ok: true });
  }

  return sendJSON(res, {}, 405);
}

const server = http.createServer(async (req, res) => {
  const pathname = decodeURIComponent(req.url.split('?')[0]);

  if (pathname.startsWith('/api/')) {
    return handleAPI(req, res, pathname, new URLSearchParams(req.url.split('?')[1] || ''));
  }

  const relative = pathname === '/' ? '/index.html' : pathname;
  const filePath = path.join(ROOT, relative);

  // Keep the served tree inside the admin resources directory.
  if (!filePath.startsWith(ROOT)) {
    res.writeHead(403);
    return res.end('Forbidden');
  }

  fs.readFile(filePath, (error, data) => {
    if (error) {
      res.writeHead(404);
      return res.end('Not found');
    }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream',
      'Cache-Control': 'no-store'
    });
    res.end(data);
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Admin WebUI preview on http://127.0.0.1:${PORT}`);
  console.log(`Serving ${ROOT}`);
});
