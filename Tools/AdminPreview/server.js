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

// Mirrors AdminWebAnalyticsPeriodPayload with plausible, deterministic numbers.
function analyticsPeriodFixture(period) {
  const p = ['7d', '30d', '365d'].includes(period) ? period : '7d';
  const now = new Date();
  const wave = (i, base, amp) => Math.max(0, Math.round(base + amp * Math.sin(i * 1.3) + (i % 3) * amp * 0.2));
  let buckets;
  if (p === '365d') {
    buckets = Array.from({ length: 12 }, (_, i) => {
      const d = new Date(now.getFullYear(), now.getMonth() - (11 - i), 1);
      return { label: d.toLocaleDateString('en', { month: 'short' }), start: d.toISOString(), voiceSessions: wave(i, 380, 90), voiceMinutes: wave(i, 16000, 4000), commands: wave(i, 900, 250), messages: wave(i, 14000, 3500), joins: wave(i, 22, 9), leaves: wave(i, 8, 5) };
    });
  } else {
    const n = p === '7d' ? 7 : 30;
    buckets = Array.from({ length: n }, (_, i) => {
      const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - (n - 1 - i));
      const label = n === 7 ? d.toLocaleDateString('en', { weekday: 'short' }) : d.toLocaleDateString('en', { day: 'numeric', month: 'short' });
      return { label, start: d.toISOString(), voiceSessions: wave(i, 14, 8), voiceMinutes: wave(i, 600, 250), commands: wave(i, 40, 18), messages: wave(i, 480, 160), joins: wave(i, 1, 1.5), leaves: i % 4 === 0 ? 1 : 0 };
    });
  }
  const sum = key => buckets.reduce((t, b) => t + b[key], 0);
  const scale = { '7d': 1, '30d': 4, '365d': 50 }[p];
  const rankPoints = (start, deltas) => deltas.map((d, i) => ({ date: new Date(now.getTime() - (deltas.length - i) * 86400000 * (p === '365d' ? 20 : p === '30d' ? 3 : 1)).toISOString(), score: start += d, rankName: 'Gold' }));
  return {
    period: p, label: { '7d': 'last 7 days', '30d': 'last 30 days', '365d': 'last 12 months' }[p], buckets,
    hourlyVoice: [6,3,1,0,0,0,1,2,3,4,5,6,8,9,10,12,15,19,24,30,36,41,33,14].map(v => v * scale),
    hourlyMessages: [20,8,3,1,0,1,4,12,25,30,34,40,52,48,45,50,58,66,72,80,90,95,70,40].map(v => v * scale),
    totals: { voiceSessions: sum('voiceSessions'), voiceSeconds: sum('voiceMinutes') * 60, averageSessionSeconds: 2460, commands: sum('commands'), failedCommands: 3 * scale,
      messages: sum('messages'), joins: sum('joins'), leaves: sum('leaves'), previousVoiceSessions: Math.round(sum('voiceSessions') * 0.88),
      previousVoiceSeconds: Math.round(sum('voiceMinutes') * 60 * 1.05), previousMessages: Math.round(sum('messages') * 0.9) },
    topVoiceUsers: [['sam', 50400, true], ['jonwatso', 41000, true], ['alex', 34860, false], ['jordan', 21900, true], ['Taylor', 9100, false]]
      .map(([name, s, live]) => ({ name, seconds: s * scale, sessions: Math.round(s / 2400) * scale, inVoiceNow: live })),
    voiceChannels: [['General Voice', 1900], ['Stream Room', 760], ['AFK', 40]].map(([title, c]) => ({ title, count: c * scale })),
    topCommands: [['/announce', 41], ['/rank', 27], ['/timestamp', 15], ['/music', 9], ['/roll', 6]].map(([title, c]) => ({ title, count: c * scale })),
    topCommandUsers: [['jonwatso', 38], ['Sam', 30], ['Alex', 17], ['Jordan', 8]].map(([title, c]) => ({ title, count: c * scale })),
    topPosters: [['Sam', 1240], ['jonwatso', 980], ['Alex', 610], ['Jordan', 330], ['Taylor', 120]].map(([title, c]) => ({ title, count: c * scale })),
    messageChannels: [['#general', 2100], ['#game-chat', 1240], ['#stream-chat', 380], ['#announcements', 60]].map(([title, c]) => ({ title, count: c * scale })),
    topWords: [['finals', 212], ['tonight', 140], ['ranked', 131], ['gg', 120], ['stream', 96], ['patch', 77], ['cashout', 70], ['lol', 64], ['squad', 51], ['vault', 40]].map(([title, c]) => ({ title, count: c * scale })),
    topEmoji: [['😂', 220], ['🔥', 140], ['💀', 96], ['👀', 71], ['🎉', 44], ['❤️', 30]].map(([title, c]) => ({ title, count: c * scale })),
    streak: { name: 'sam', days: 5 },
    rankSeries: [
      { name: 'jonwatso', game: 'THE FINALS', points: rankPoints(27100, [0, 420, 380, -210, 816, -183, -674]) },
      { name: 'sam', game: 'THE FINALS', points: rankPoints(17600, [0, 300, 120, 400]) }
    ],
    clipsByGame: [['THE FINALS', 3], ['Helldivers 2', 2], ['Apex Legends', 2], ['Minecraft', 3]].map(([title, c]) => ({ title, count: c * scale })),
    messagesAvailable: true, rewindEnabled: true
  };
}

async function handleAPI(req, res, pathname, query) {
  if (req.method === 'GET') {
    switch (pathname) {
      case '/api/media/game-art': return sendGameArt(res, query.get('game'));
      case '/api/me': return sendJSON(res, fixtures.me);
      case '/api/auth/options': return sendJSON(res, fixtures.authOptions);
      case '/api/overview': return sendJSON(res, fixtures.overview);
      case '/api/status': return sendJSON(res, fixtures.status);
      case '/api/analytics': return sendJSON(res, { ...fixtures.analytics, period: analyticsPeriodFixture(query.get('period')) });
      case '/api/rewind': return sendJSON(res, fixtures.rewind);
      case '/api/announcer': return sendJSON(res, announcer);
      case '/api/config': return sendJSON(res, config);
      case '/api/settings': return sendJSON(res, { prefix: fixtures.config.commands.prefix });
      case '/api/commands': return sendJSON(res, fixtures.commands);
      case '/api/access': return sendJSON(res, fixtures.access);
      case '/api/activity': return sendJSON(res, fixtures.activity);
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

    if (pathname === '/api/access/update') {
      // Same guards as AdminWebAccessUpdate.validate.
      const ids = [...new Set((body.allowedUserIDs || []).map(id => String(id).trim()).filter(Boolean))];
      if (!ids.every(id => /^\d{15,22}$/.test(id))) return sendJSON(res, { error: 'invalid_id' }, 400);
      if (body.restrictToListedUsers && !ids.length) return sendJSON(res, { error: 'empty_list' }, 400);
      if (body.restrictToListedUsers && !String(fixtures.me.id).startsWith('local:') && !ids.includes(fixtures.me.id)) return sendJSON(res, { error: 'self_lockout' }, 400);
      fixtures.access.restrictToListedUsers = !!body.restrictToListedUsers;
      fixtures.access.allowedUserIDs = ids;
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
