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
const { execFile, execFileSync } = require('child_process');

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

// ---- Live Game Tracker post preview ----------------------------------
// Compiles the app's real GameAnnouncementRenderer (plus a tiny CLI in
// GamePostRenderer/) with swiftc, so the style editor previews exactly what
// the bot would post. Rebuilt when any of the Swift sources change; until it
// is ready, or without swiftc, the pre-rendered fixtures stand in.
const RENDERER_DIR = path.join(__dirname, 'GamePostRenderer');
const RENDERER_BIN = path.join(__dirname, '.build', 'game-post-renderer');
const APP_SOURCES = path.resolve(__dirname, '../../Sources/SwiftBot');
const RENDERER_SOURCES = [
  ...fs.readdirSync(RENDERER_DIR).filter((f) => f.endsWith('.swift')).map((f) => path.join(RENDERER_DIR, f)),
  ...['Models/GameTrackingModels.swift', 'Models/GameMetrics.swift', 'Models/GameRankTiers.swift',
    'Models/GameAnnouncementStyle.swift', 'Services/GameAnnouncementRenderer.swift',
    'Services/GameSessionSummaryBuilder.swift', 'Models/FinalsIDModels.swift', 'Services/FinalsIDRuntime.swift']
    .map((f) => path.join(APP_SOURCES, f))
];
let rendererReady = false;

function buildGamePostRenderer() {
  try {
    const built = fs.statSync(RENDERER_BIN).mtimeMs;
    if (RENDERER_SOURCES.every((f) => fs.statSync(f).mtimeMs < built)) { rendererReady = true; return; }
  } catch {}
  fs.mkdirSync(path.dirname(RENDERER_BIN), { recursive: true });
  console.log('[gametracker] compiling the post renderer for live previews…');
  execFile('swiftc', ['-O', '-o', RENDERER_BIN, ...RENDERER_SOURCES], (error, _out, stderr) => {
    if (error) {
      console.log('[gametracker] renderer build failed; previews use fixtures.\n' + String(stderr).split('\n').filter((l) => l.includes('error')).slice(0, 5).join('\n'));
      return;
    }
    rendererReady = true;
    console.log('[gametracker] live post previews ready');
  });
}
buildGamePostRenderer();
// Pick up edits to the renderer while the server runs.
RENDERER_SOURCES.forEach((f) => fs.watchFile(f, { interval: 1500 }, () => { rendererReady = false; buildGamePostRenderer(); }));

function renderGamePostPreview(style) {
  if (rendererReady) {
    const player = (gametracker.players || []).find((p) => p.isEnabled && p.score) || gametracker.players?.[0];
    try {
      return JSON.parse(execFileSync(RENDERER_BIN, [], {
        input: JSON.stringify({ style, player: player && { displayName: player.displayName, score: player.score, rankName: player.rankName, season: player.season, discordUserID: player.discordUserID } }),
        timeout: 3000
      }).toString());
    } catch (error) {
      console.log('[gametracker] renderer failed:', error.message);
    }
  }
  return fixtures.gametrackerStylePreviews[style?.layout] || fixtures.gametrackerStylePreviews.card;
}

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
    featureUses: { announcer: 72 * scale, patchy: 8 * scale, gametracker: 12 * scale, sweep: 140 * scale },
    messagesAvailable: true, rewindEnabled: true
  };
}

function textChannelsForPreview() {
  return (fixtures.sweep.textChannelsByServer['1001'] || []).slice(0, 12);
}

// Replay fixtures, mirroring ServerReplay / PersonalReplay / the recap APIs.
const replayMembers = [['412378964087275541', 'jonwatso'], ['280129381292318720', 'Sam'], ['280129381292318721', 'Alex'], ['280129381292318722', 'Jordan'], ['280129381292318723', 'Taylor'], ['280129381292318724', 'Morgan']];
const recapState = { channelID: 't101', monthly: true, yearly: false, lastMonthlyKey: null, lastYearlyKey: null, personalDMs: false };
let dmProgress = null;
// Operators, shaped like AdminWebOperatorsPayload.
const operatorState = {
  byNode: { 'Preview Mac': '412378964087275541' },
  alerts: { discordDisconnected: true, nodeOffline: true, recordingsUnreachable: true, errorBurst: true, roleChanges: false }
};
const operatorAlertTitles = { discordDisconnected: 'Discord disconnected', nodeOffline: 'Mac went offline', recordingsUnreachable: 'Recordings folder unreachable', errorBurst: 'Errors piling up', roleChanges: 'Role changes' };
function operatorsFixture() {
  const names = ['Preview Mac', 'Studio', 'Old MacBook'];
  return {
    thisNode: 'Preview Mac',
    nodes: names.map(name => ({ name, operatorID: operatorState.byNode[name] || null, isThisNode: name === 'Preview Mac' })),
    alerts: Object.keys(operatorAlertTitles).map(id => ({ id, title: operatorAlertTitles[id], enabled: !!operatorState.alerts[id] })),
    members: fixtures.config.userTimezones.members
  };
}
// Who was in each sample clip, as AppModel.clipPeopleIndex would work out.
const clipCrew = [['300000000000000003', 'Gabe'], ['280129381292318720', 'Sam'], ['280129381292318721', 'Alex'], ['412378964087275541', 'jonwatso'], ['280129381292318722', 'Jordan']];
const sourceOwners = { clips: '412378964087275541' };
function withClipPeople(item, i) {
  const recordedByID = sourceOwners.clips || null;
  const people = clipCrew.filter(([id], j) => id === recordedByID || (j === 0 ? i % 3 !== 2 : (i + j) % 3 === 0)).map(([id, name]) => ({ id, name }));
  return withGameFix({ ...item, people, recordedByID });
}
// Fix Match, as AppModel.resolvedMediaGameName: this clip's fix, then one
// for every clip detected as the same game, then the filename's game.
const gameFixes = { clip: {}, detected: {} };
function withGameFix(item) {
  const detected = item.gameName;
  const clipFix = gameFixes.clip[item.id];
  const gameName = clipFix || gameFixes.detected[detected.toLowerCase()] || detected;
  return { ...item, gameName, detectedGameName: detected, gameMatch: clipFix ? 'clip' : gameName !== detected ? 'detected' : null };
}
const previewSteamGames = ['Call of Duty®: Black Ops 6', 'Call of Duty®: Modern Warfare® III', 'THE FINALS', 'Apex Legends™', 'Counter-Strike 2', 'Marvel Rivals', 'Helldivers™ 2', 'Overwatch® 2']
  .map((name, i) => ({ name, steamAppID: String(2_000_000 + i) }));
// SwiftMesh: a Primary with one Fail Over, mirroring AdminWebSwiftMeshPayload.
const meshState = { handoverScheduledAt: null, handoverEndsAt: null, lastRunAt: new Date(Date.now() - 3 * 86400000).toISOString(), lastRunOK: true, forgotten: new Set(), icons: {} };
function swiftMeshFixture() {
  const cfg = config.swiftMesh;
  const mode = { leader: 'Leader', standby: 'Standby', standalone: 'Standalone' }[String(cfg.mode).toLowerCase()] || cfg.mode;
  const now = Date.now();
  if (meshState.handoverScheduledAt && new Date(meshState.handoverScheduledAt).getTime() <= now) {
    meshState.handoverScheduledAt = null;
    meshState.handoverEndsAt = new Date(now + 60000).toISOString();
  }
  if (meshState.handoverEndsAt && new Date(meshState.handoverEndsAt).getTime() <= now) {
    meshState.handoverEndsAt = null;
    meshState.lastRunAt = new Date().toISOString();
    meshState.lastRunOK = true;
  }
  const nodes = mode === 'Standalone' ? [] : [
    { id: 'n1', displayName: cfg.nodeName, hostname: 'preview-mac.local', role: mode === 'Leader' ? 'leader' : 'standby', status: 'healthy', hardwareModel: 'Mac16,10', cpuName: 'Apple M4 Pro', memoryBytes: 48 * 1073741824, uptimeSeconds: 4 * 86400 + 7200, jobsActive: 1, latencyMs: 3, isThisNode: true, follower: null },
    { id: 'n2', displayName: 'Studio', hostname: 'studio.local', role: mode === 'Leader' ? 'standby' : 'leader', status: 'healthy', hardwareModel: 'Mac14,13', cpuName: 'Apple M2 Max', memoryBytes: 64 * 1073741824, uptimeSeconds: 12 * 86400, jobsActive: 0, latencyMs: 18,
      isThisNode: false, follower: mode === 'Leader' ? { mode: 'standby', gatewayConnected: false, outputAllowed: false, lastEventAt: null, activeVoiceMembers: 4, discordLatencyMs: 61, collectedAt: new Date().toISOString() } : null },
    { id: 'n3', displayName: 'Old MacBook', hostname: 'macbook.local', role: 'standby', status: 'disconnected', hardwareModel: 'MacBookPro18,3', cpuName: 'Apple M1 Pro', memoryBytes: 16 * 1073741824, uptimeSeconds: 0, jobsActive: 0, latencyMs: null, isThisNode: false, follower: null }
  ].filter(n => !meshState.forgotten.has(n.displayName));
  return {
    configuredMode: mode, runtimeMode: meshState.handoverEndsAt && mode === 'Leader' ? 'Standby' : mode, runtimeState: 'idle',
    nodeName: cfg.nodeName, leaderAddress: cfg.leaderAddress || 'studio.local', leaderPort: cfg.leaderPort, listenPort: cfg.listenPort, leaderTerm: 7,
    workerOffloadEnabled: cfg.workerOffloadEnabled, offloadAIReplies: cfg.offloadAIReplies, offloadWikiLookups: cfg.offloadWikiLookups,
    autoReclaimAfterHours: cfg.autoReclaimAfterHours, autoReclaimRemainingSeconds: mode === 'Standby' ? 5 * 3600 + 720 : null,
    server: { state: mode === 'Standalone' ? 'inactive' : 'listening', text: mode === 'Standalone' ? 'Disabled' : `Listening on ${cfg.listenPort}` },
    worker: { state: mode === 'Standalone' ? 'inactive' : 'connected', text: mode === 'Leader' ? '1 follower registered' : mode === 'Standby' ? 'Synced with Primary 8s ago' : 'Local only' },
    diagnostics: mode === 'Standalone' ? 'No diagnostics yet' : 'Mesh sync healthy. Last pull from Studio 8s ago (14 files, 0 conflicts).',
    lastJobRoute: 'remote', lastJobNode: 'Studio', lastJobSummary: 'AI reply via worker',
    registeredWorkers: mode === 'Leader' ? nodes.filter(n => !n.isThisNode && n.status !== 'disconnected').length : 0,
    localGatewayLatencyMs: 42,
    handover: { isActive: !!meshState.handoverEndsAt, scheduledAt: meshState.handoverScheduledAt, endsAt: meshState.handoverEndsAt, lastRunAt: meshState.lastRunAt, lastRunOK: meshState.lastRunOK,
      canRun: mode === 'Leader' && !meshState.handoverScheduledAt && !meshState.handoverEndsAt },
    nodes
  };
}
function replayFixture(periodKey) {
  const isYear = /^\d{4}$/.test(periodKey);
  const now = new Date();
  const year = Number(periodKey.slice(0, 4));
  const month = isYear ? null : Number(periodKey.slice(5, 7));
  const scale = isYear ? 1 : 1 / 10;
  const n = (v) => Math.max(0, Math.round(v * scale));
  const timeline = isYear
    ? Array.from({ length: 12 }, (_, i) => ({ label: new Date(year, i, 1).toLocaleDateString('en', { month: 'short' }), messages: year === now.getFullYear() && i > now.getMonth() ? 0 : 9000 + Math.round(6000 * Math.sin(i * 0.9 + 1)) + i * 300, voiceMinutes: 0 }))
    : Array.from({ length: new Date(year, month, 0).getDate() }, (_, i) => ({ label: String(i + 1), messages: 120 + Math.round(240 * Math.abs(Math.sin(i * 0.7))) + (i % 7 === 5 ? 260 : 0), voiceMinutes: 0 }));
  const messages = timeline.reduce((t, b) => t + b.messages, 0);
  const title = isYear ? String(year) : new Date(year, month - 1, 1).toLocaleDateString('en', { month: 'long', year: 'numeric' });
  return {
    guildID: '1001', guildName: 'Swift Lounge', periodKey, periodTitle: title, isYear,
    isComplete: isYear ? year < now.getFullYear() : (year < now.getFullYear() || month < now.getMonth() + 1),
    messages, words: messages * 7, activeDays: isYear ? 274 : timeline.length - 2, chattingMembers: isYear ? 64 : 31,
    busiestDay: isYear ? `${year}-03-14` : `${periodKey}-${String(Math.min(timeline.length, 13)).padStart(2, '0')}`, busiestDayMessages: isYear ? 2412 : 640, peakHour: 21,
    timeline, hourly: [20,8,3,1,0,1,4,12,25,30,34,40,52,48,45,50,58,66,72,80,90,95,70,40],
    topMembers: replayMembers.slice(0, 6).map(([id, title], i) => ({ id, title, count: n([24100, 19880, 12004, 8810, 5020, 2400][i]), signature: ['cashout', 'ranked', 'vault', 'patch', 'stream', null][i] || undefined })),
    topChannels: [['#general', 61000], ['#game-chat', 38400], ['#stream-chat', 9100], ['#memes', 6200]].map(([title, c]) => ({ title, count: n(c) })),
    // Ranked against the rest of the archive, as AppModel.serverReplay does
    // once there's history: each term carries its "new" / "4× usual" note.
    wordsAreDistinctive: true,
    topWords: [['finals', 4821, '6× usual'], ['cashout', 1702, 'new'], ['ranked', 3544, '2.4× usual'], ['vault', 990, 'new'], ['patch', 1980, '3× usual'], ['stream', 2104, '1.8× usual'], ['gabe', 760, '2.1× usual'], ['tonight', 3902, '1.6× usual']].map(([title, c, note]) => ({ title, count: n(c), note })),
    topPhrases: [['gg guys', 812, '2× usual'], ['world tour', 640, 'new'], ['ranked grind', 410, '4.5× usual']].map(([title, c, note]) => ({ title, count: n(c), note })),
    topEmoji: [['😂', 5210], ['🔥', 2410], ['💀', 1890], ['👀', 1200], ['🎉', 1044]].map(([title, c]) => ({ title, count: n(c) })),
    voiceSeconds: n(1_840_000), voiceSessions: n(2900),
    topVoiceMembers: replayMembers.slice(0, 5).map(([id, title], i) => ({ id, title, count: n([402000, 351000, 219000, 140000, 92000][i]) })),
    topVoiceChannels: [['General Voice', 1_200_000], ['Stream Room', 520_000], ['AFK', 40_000]].map(([title, c]) => ({ title, count: n(c) })),
    commands: n(11716), topCommands: [{ title: '/announce', count: n(4100) }, { title: '/rank', count: n(2700) }],
    joins: n(181), leaves: n(64),
    clipsByGame: [{ title: 'THE FINALS', count: n(120) }, { title: 'Helldivers 2', count: n(64) }],
    rankChanges: [{ name: 'jonwatso', game: 'THE FINALS', from: 21002, to: 28160, rankName: 'Gold' }, { name: 'sam', game: 'THE FINALS', from: 15100, to: 18420, rankName: 'Gold' }]
  };
}

async function handleAPI(req, res, pathname, query) {
  if (req.method === 'GET') {
    switch (pathname) {
      case '/api/media/game-details':
        if ((query.get('game') || '').toLowerCase() !== 'the finals') return sendJSON(res, { error: 'details_unavailable' }, 404);
        return sendJSON(res, { appID: '2073850', description: 'Preview description: a competitive combat game show with destructible arenas and team-based action.', genres: ['Action', 'Free to Play'], developers: ['Embark Studios'], positivePercent: 84, reviewLabel: 'Very Positive', reviewCount: 123456 }); // Illustrative preview rating, not live Steam data.
      case '/api/media/game-art': return sendGameArt(res, query.get('game'));
      case '/api/me':
        if (!signedIn) return sendJSON(res, { error: 'unauthorized' }, 401);
        return sendJSON(res, signedInAs === 'member'
          ? { ...fixtures.me, id: '300000000000000003', username: 'gabe', globalName: 'Gabe', role: 'member' }
          : { ...fixtures.me, role: 'admin' });
      case '/api/member/replay': {
        // Gabe's own Replay, shaped like AdminWebMemberReplayPayload.
        const now = new Date();
        const months = Array.from({ length: 14 }, (_, i) => { const d = new Date(now.getFullYear(), now.getMonth() - i, 1); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; });
        const periods = [];
        months.forEach(m => { const y = m.slice(0, 4); if (!periods.includes(y)) periods.push(y); periods.push(m); });
        const key = periods.includes(query.get('period')) ? query.get('period') : String(now.getFullYear());
        const r = replayFixture(key);
        const i = 2;
        const msgs = r.topMembers[i]?.count || 0;
        return sendJSON(res, {
          rewindEnabled: true, guilds: [{ id: '1001', name: 'Swift Lounge' }, { id: '1002', name: 'Dev Bunker' }], guildID: query.get('guild') || '1001', periods, periodKey: key,
          replay: { guildID: '1001', guildName: 'Swift Lounge', userID: '300000000000000003', name: 'Gabe', periodKey: r.periodKey, periodTitle: r.periodTitle,
            messages: msgs, words: msgs * 6, activeDays: r.isYear ? 161 : 19, busiestDay: r.busiestDay, busiestDayMessages: Math.round(msgs / 30),
            rank: i + 1, rankedMembers: r.chattingMembers, voiceSeconds: r.topVoiceMembers[i]?.count || 0, voiceSessions: 100, longestSessionSeconds: 15800,
            favouriteVoiceChannel: 'General Voice', voiceRank: i + 1, commands: 700, signatureWords: [{ title: 'cashout', count: 212, note: '6× everyone else' }, { title: 'vault', count: 88, note: 'only you' }, { title: 'tonight', count: 140, note: '2.5× everyone else' }], signaturePhrases: [{ title: 'one more', count: 41, note: '3× everyone else' }], previousPeriodTitle: r.isYear ? String(Number(key) - 1) : 'last month',
            previousMessages: Math.round(msgs * 0.8), previousVoiceSeconds: Math.round((r.topVoiceMembers[i]?.count || 0) * 1.1) }
        });
      }
      case '/api/auth/options': return sendJSON(res, { ...fixtures.authOptions, botOnline: true });
      case '/api/overview': return sendJSON(res, fixtures.overview);
      case '/api/status': return sendJSON(res, fixtures.status);
      case '/api/updates': return sendJSON(res, fixtures.updates);
      case '/api/bot/permissions': return sendJSON(res, { ...fixtures.botPermissions, checkedAt: new Date().toISOString() });
      case '/api/analytics': return sendJSON(res, { ...fixtures.analytics, period: analyticsPeriodFixture(query.get('period')) });
      case '/api/rewind': return sendJSON(res, fixtures.rewind);
      case '/api/rewind/recaps': {
        const now = new Date();
        const months = Array.from({ length: 21 }, (_, i) => { const d = new Date(now.getFullYear(), now.getMonth() - i, 1); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; });
        return sendJSON(res, { guilds: [{ id: '1001', name: 'Swift Lounge', ...recapState, channels: textChannelsForPreview() }], months,
          dmOptOutCount: 3, lastCatchUpAt: new Date(Date.now() - 5 * 3600000).toISOString(), catchUpAvailable: true, dmProgress });
      }
      case '/api/rewind/recipients': {
        return sendJSON(res, { count: /^\d{4}$/.test(query.get('period') || '') ? 61 : 28 });
      }
      case '/api/rewind/replay': return sendJSON(res, replayFixture(query.get('period') || String(new Date().getFullYear())));
      case '/api/member/clips': {
        // Clips Gabe was in, with who else was there, like AppModel.memberClips.
        const all = fixtures.media.items.map(withClipPeople).map(item => ({ ...item, nodeName: '', sourceName: '', relativePath: '' }))
          .filter(item => item.people.some(p => p.id === '300000000000000003'));
        const game = query.get('game');
        const items = game ? all.filter(i => i.gameName === game) : all;
        const pageSize = Number(query.get('pageSize')) || 24;
        const games = [...new Set(all.map(i => i.gameName))];
        return sendJSON(res, { generatedAt: new Date().toISOString(), sources: [], items: items.slice(0, pageSize), games,
          gameSummaries: games.map(name => ({ name, clipCount: all.filter(i => i.gameName === name).length, latestAt: null, totalBytes: 0 })),
          selectedSourceID: null, selectedDateRange: 'all', selectedGame: game || null, page: 1, pageSize, totalItems: items.length, totalPages: 1 });
      }
      case '/api/rewind/member': {
        const id = query.get('user');
        const r = replayFixture(query.get('period') || String(new Date().getFullYear()));
        const i = Math.max(0, replayMembers.findIndex(m => m[0] === id));
        const msgs = r.topMembers[i]?.count || 0;
        return sendJSON(res, { guildID: '1001', guildName: 'Swift Lounge', userID: id, name: replayMembers[i][1], periodKey: r.periodKey, periodTitle: r.periodTitle,
          messages: msgs, words: msgs * 6, activeDays: r.isYear ? 201 - i * 20 : 22 - i, busiestDay: r.busiestDay, busiestDayMessages: Math.round(msgs / 30),
          rank: i + 1, rankedMembers: r.chattingMembers, voiceSeconds: r.topVoiceMembers[i]?.count || 0, voiceSessions: 120 - i * 10, longestSessionSeconds: 17400 - i * 1800,
          favouriteVoiceChannel: 'General Voice', voiceRank: i + 1, commands: 900 - i * 100, optedOut: false, signatureWords: [{ title: 'cashout', count: 212, note: '6× everyone else' }, { title: 'vault', count: 88, note: 'only you' }, { title: 'tonight', count: 140, note: '2.5× everyone else' }], signaturePhrases: [{ title: 'one more', count: 41, note: '3× everyone else' }], });
      }
      case '/api/rewind/phrase': {
        const q = (query.get('q') || '').trim();
        if (/^(zzz|nothing)/i.test(q)) return sendJSON(res, { phrase: q, total: 0, messages: 0, scanned: 182441, firstSeen: null, lastSeen: null, byUser: [], byMonth: [], topChannel: null });
        return sendJSON(res, { phrase: q, total: 812, messages: 790, scanned: 182441, firstSeen: '2026-01-03T20:11:00Z', lastSeen: new Date().toISOString(),
          byUser: replayMembers.slice(0, 5).map(([id, title], i) => ({ id, title, count: [301, 212, 140, 88, 41][i] })),
          byMonth: Array.from({ length: 9 }, (_, i) => ({ title: `2026-${String(i + 1).padStart(2, '0')}`, count: 40 + Math.round(70 * Math.abs(Math.sin(i))) })),
          topChannel: '#game-chat' });
      }
      case '/api/announcer': return sendJSON(res, announcer);
      case '/api/config': return sendJSON(res, config);
      case '/api/settings': return sendJSON(res, { prefix: fixtures.config.commands.prefix });
      case '/api/commands': return sendJSON(res, fixtures.commands);
      case '/api/music/preview': return sendJSON(res, fixtures.musicPreview);
      case '/api/access': return sendJSON(res, fixtures.access);
      case '/api/activity': return sendJSON(res, fixtures.activity);
      case '/api/activity/export':
        res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'Content-Disposition': 'attachment; filename="SwiftBot-Diagnostics-preview.txt"' });
        return res.end('=== SwiftBot Diagnostic Report ===\n(preview)\n');
      case '/api/automations': {
        const category = query.get('category') || 'automation';
        return sendJSON(res, fixtures.automations(category, automationRules[category]));
      }
      case '/api/welcome-flow': return sendJSON(res, welcomeFlow);
      case '/api/patchy': return sendJSON(res, patchy);
      case '/api/aibots': return sendJSON(res, fixtures.aibots);
      case '/api/swiftmesh': {
        const mesh = swiftMeshFixture();
        mesh.nodes = mesh.nodes.map(n => ({ ...n, operatorID: operatorState.byNode[n.displayName] || null, iconOverride: meshState.icons[n.displayName] || null }));
        mesh.iconOptions = [
          { symbol: 'laptopcomputer', label: 'Laptop' }, { symbol: 'macbook', label: 'MacBook' },
          { symbol: 'desktopcomputer', label: 'Desktop' }, { symbol: 'macmini', label: 'Mac mini' },
          { symbol: 'macstudio', label: 'Mac Studio' }, { symbol: 'macpro.gen3', label: 'Mac Pro' },
          { symbol: 'server.rack', label: 'Server rack' }
        ];
        return sendJSON(res, mesh);
      }
      case '/api/operators': return sendJSON(res, operatorsFixture());
      case '/api/wikibridge': return sendJSON(res, wikibridge);
      case '/api/sweep': return sendJSON(res, sweep);
      case '/api/gametracker': {
        return sendJSON(res, { ...gametracker, stylePreview: renderGamePostPreview(gametracker.announcementStyle || {}) });
      }
      case '/api/media': {
        const game = query.get ? query.get('game') : query.game;
        const range = (query.get ? query.get('dateRange') : query.dateRange) || 'all';
        const days = { '7d': 7, '30d': 30, '90d': 90 }[range];
        const person = query.get('person');
        const inRange = fixtures.media.items.map(withClipPeople)
          .filter(item => !days || Date.now() - new Date(item.modifiedAt).getTime() < days * 86400000)
          .filter(item => !person || item.people.some(p => p.id === person));
        const items = inRange.filter(item => !game || item.gameName === game);
        const gameSummaries = [...new Set(inRange.map(i => i.gameName))].map(name => {
          const entries = inRange.filter(i => i.gameName === name);
          return { name, clipCount: entries.length, latestAt: entries.map(i => i.modifiedAt).sort().pop(), totalBytes: entries.reduce((t, i) => t + i.sizeBytes, 0) };
        }).sort((a, b) => b.latestAt.localeCompare(a.latestAt));
        return sendJSON(res, { ...fixtures.media, sources: fixtures.media.sources.map(s => ({ ...s, ownerID: sourceOwners[s.id] || null })), items, totalItems: items.length, gameSummaries, games: gameSummaries.map(g => g.name).sort(), selectedGame: game || null, selectedDateRange: range });
      }
      case '/api/media/game-search': {
        const term = (query.get('q') || '').toLowerCase().replace(/[^a-z0-9]/g, '');
        return sendJSON(res, term ? previewSteamGames.filter(g => g.name.toLowerCase().replace(/[^a-z0-9]/g, '').includes(term)) : []);
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

    // Host actions: bot lifecycle, tests, updates. Mutate the fixtures so the
    // page's follow-up reads see the change.
    if (['/api/cache/clear', '/api/activity/clear', '/api/bot/permissions/force-rejoin'].includes(pathname)) {
      console.log(`[host] ${pathname}`, JSON.stringify(body));
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/bot/start' || pathname === '/api/bot/restart') {
      fixtures.status.botStatus = 'connecting';
      setTimeout(() => { fixtures.status.botStatus = 'running'; }, 3000);
      console.log(`[bot] ${pathname}`);
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/bot/stop') {
      fixtures.status.botStatus = 'stopped';
      console.log('[bot] stopped');
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/updates/check') {
      fixtures.updates.isChecking = true;
      setTimeout(() => {
        Object.assign(fixtures.updates, { isChecking: false, lastCheckedAt: new Date().toISOString(), availableVersion: '1.28.0', availableBuild: '2026100309', releaseNotesURL: 'https://example.com/release-notes/1.28.0.html', readyToInstall: fixtures.updates.unattended });
      }, 2500);
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/updates/settings') {
      if (body.automaticChecks !== undefined) fixtures.updates.automaticChecks = !!body.automaticChecks;
      if (body.unattended !== undefined) {
        if (body.unattended && !fixtures.updates.automaticChecks) return sendJSON(res, { error: 'failed', message: 'Turn on automatic checks first.' }, 409);
        fixtures.updates.unattended = !!body.unattended;
      }
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/updates/install') {
      if (!fixtures.updates.readyToInstall) return sendJSON(res, { error: 'failed', message: 'No update is downloaded yet.' }, 409);
      console.log('[updates] install requested');
      return sendJSON(res, { ok: true });
    }
    if (['/api/announcer/test', '/api/announcer/reconnect', '/api/welcome-flow/test', '/api/welcome-flow/invites/refresh', '/api/sweep/draft/test-mvp'].includes(pathname)) {
      console.log(`[host action] ${pathname}`);
      if (pathname === '/api/welcome-flow/invites/refresh') {
        welcomeFlow.invites = [{ code: 'hewetts', channelName: 'general', uses: 12 }, { code: 'aB3xYz', channelName: 'welcome', uses: 3 }];
      }
      if (pathname === '/api/sweep/draft/test-mvp') return sendJSON(res, { error: 'failed', message: 'No voice activity was found for this server in the rolling seven-day window.' }, 409);
      return sendJSON(res, { ok: true });
    }

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
        case '/api/patchy/target/test': {
          // Mirrors the app: the reply says whether the post went out.
          const target = find(body.targetID);
          if (!target || !target.channelId) {
            return sendJSON(res, { error: 'test_failed', message: 'Choose a channel for this source first.' }, 400);
          }
          target.lastCheckedAt = target.lastRunAt = new Date().toISOString();
          target.lastStatus = 'Delivered test notification';
          console.log(`[${pathname}]`, JSON.stringify(body));
          return sendJSON(res, { ok: true, message: 'Test post sent.' });
        }
        case '/api/patchy/target/pull':
        case '/api/patchy/check': {
          const now = new Date().toISOString();
          (body.targetID ? [find(body.targetID)] : patchy.targets).filter(Boolean).forEach((t) => {
            t.lastCheckedAt = now;
            if (pathname !== '/api/patchy/check') t.lastRunAt = now;
            t.lastStatus = 'Up to date';
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

    if (pathname === '/api/gametracker/credential') {
      // Like handleGameProviderCredential: write-only, and a key starting
      // "bad" is rejected the way finals.id's 401 is. The key is never logged.
      const provider = gametracker.catalog.providers.find((p) => p.id === body.provider);
      if (!provider) return sendJSON(res, { error: 'invalid_payload' }, 400);
      if (body.remove) {
        Object.assign(provider, { hasCredential: false, credentialHint: null, isConfigured: false, credentialUpdatedAt: new Date().toISOString() });
        return sendJSON(res, { ok: true });
      }
      const token = String(body.token || '').trim();
      if (/^bad/i.test(token)) return sendJSON(res, { error: 'rejected', message: 'finals.id didn’t accept that key. Nothing was changed.' }, 400);
      if (/^old/i.test(token)) return sendJSON(res, { error: 'reauth_required', message: 'For security, sign out and back in to change API keys. You signed in more than 15 minutes ago.' }, 401);
      Object.assign(provider, { hasCredential: true, credentialHint: token.length >= 12 ? token.slice(-4) : null, isConfigured: true, credentialUpdatedAt: new Date().toISOString() });
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/gametracker/preview') {
      return sendJSON(res, renderGamePostPreview(body));
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
      } else if (body.action === 'updateStyle') {
        gametracker.announcementStyle = { ...body.style };
      } else if (body.action === 'sendTest') {
        console.log('[gametracker] would post test announcements for', body.playerID);
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
        case '/api/automations/simulate': {
          // A rough stand-in: the real trace comes from AutomationService.
          const r = body.rule;
          const input = { username: body.input?.username || 'john_doe', channelId: body.input?.channelId || 'chan-123', messageContent: body.input?.messageContent || 'Hello world!', voiceDurationSeconds: body.input?.voiceDurationSeconds ?? 300 };
          const filterTraces = (r.filters || []).map(f => ({ filterId: f.id, kind: f.kind, matched: true, detail: 'Filter matched criteria' }));
          const stepTraces = (r.steps || []).map(st => ({ stepId: st.id, kind: st.kind, executed: st.kind !== 'log', detail: st.kind === 'delay' ? `Would wait ${st.delaySeconds || 0}s` : (st.kind === 'log' ? 'Nothing to log' : `Would ${st.kind}`) }));
          return sendJSON(res, { input, result: { triggerMatched: true, filtersMatched: true, filterTraces, stepTraces } });
        }
        case '/api/automations/draft':
          return sendJSON(res, { error: 'Drafting needs Apple Intelligence on the bot.' });
      }
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/media/game-match' && body.fromGame) {
      const name = String(body.gameName || '').replace(/[®™©]/g, '').split(/\s+/).filter(Boolean).join(' ');
      for (const item of fixtures.media.items.map(withGameFix)) {
        if (gameFixes.clip[item.id]) { if (gameFixes.clip[item.id] === body.fromGame) gameFixes.clip[item.id] = name; continue; }
        if (item.gameName === body.fromGame) gameFixes.detected[item.detectedGameName.toLowerCase()] = name;
      }
      console.log(`[media] fix match ${body.fromGame} → ${name}`);
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/media/game-match') {
      const item = fixtures.media.items.find(i => i.id === body.itemID);
      if (!item) return sendJSON(res, { error: 'invalid_payload' }, 400);
      const name = String(body.gameName || '').trim();
      if (body.applyToDetected) {
        if (name && name.toLowerCase() !== item.gameName.toLowerCase()) gameFixes.detected[item.gameName.toLowerCase()] = name;
        else delete gameFixes.detected[item.gameName.toLowerCase()];
        delete gameFixes.clip[item.id];
      } else if (name) {
        gameFixes.clip[item.id] = name;
      } else {
        delete gameFixes.clip[item.id];
      }
      console.log(`[media] fix match ${item.id} → ${name || '(detected)'}${body.applyToDetected ? ' for all' : ''}`);
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/media/source-owner') {
      if (body.userID) sourceOwners[body.sourceID] = body.userID; else delete sourceOwners[body.sourceID];
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/access/members') {
      fixtures.access.memberAccessEnabled = !!body.enabled;
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

    if (pathname === '/api/rewind/recaps/update') {
      Object.assign(recapState, { channelID: body.channelID || '', monthly: !!body.monthly, yearly: !!body.yearly, personalDMs: !!body.personalDMs });
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/rewind/recaps/dm') {
      if (dmProgress && !dmProgress.finishedAt) return sendJSON(res, { error: 'already_sending' }, 400);
      const total = /^\d{4}$/.test(body.period) ? 61 : 28;
      dmProgress = { guildID: body.guildID, periodKey: body.period, total, processed: 0, sent: 0, failed: 0, startedAt: new Date().toISOString(), finishedAt: null };
      const tick = setInterval(() => {
        const step = Math.min(4, total - dmProgress.processed);
        dmProgress.processed += step;
        const closed = dmProgress.processed % 12 < step ? 1 : 0;
        dmProgress.failed += closed;
        dmProgress.sent += step - closed;
        if (dmProgress.processed >= total) { dmProgress.finishedAt = new Date().toISOString(); clearInterval(tick); }
      }, 1000);
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/rewind/recaps/post') {
      return recapState.channelID ? sendJSON(res, { ok: true }) : sendJSON(res, { error: 'no_channel' }, 400);
    }

    if (pathname === '/api/commands/toggle') {
      const item = fixtures.commands.items.find(i => i.name === body.name);
      if (!item) return sendJSON(res, { error: 'unknown_command' }, 404);
      item.enabled = !!body.enabled;
      return sendJSON(res, { ok: true });
    }

    if (pathname === '/api/operators') {
      if (body.node) { if (body.userID) operatorState.byNode[body.node] = body.userID; else delete operatorState.byNode[body.node]; }
      else if (body.alert) operatorState.alerts[body.alert] = !!body.enabled;
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/operators/test') {
      return operatorState.byNode['Preview Mac'] ? sendJSON(res, { ok: true }) : sendJSON(res, { error: 'no_operator' }, 409);
    }
    if (pathname === '/api/swiftmesh/action') {
      const mesh = swiftMeshFixture();
      switch (body.action) {
        case 'handoverTest':
          if (!mesh.handover.canRun) return sendJSON(res, { error: 'A handover test is already scheduled or running.' }, 409);
          meshState.handoverScheduledAt = new Date(Date.now() + 90000).toISOString();
          break;
        case 'cancelHandoverTest':
          meshState.handoverScheduledAt = null;
          break;
        case 'promote':
          if (mesh.configuredMode !== 'Standby') return sendJSON(res, { error: 'Only a Fail Over node can be promoted.' }, 409);
          config.swiftMesh.mode = 'Leader';
          break;
        case 'forget':
          meshState.forgotten.add(body.node);
          break;
        case 'setIcon':
          if (body.icon) meshState.icons[body.node] = body.icon; else delete meshState.icons[body.node];
          console.log(`[swiftmesh] icon ${body.node} → ${body.icon || 'auto'}`);
          break;
        default:
          return sendJSON(res, { error: 'Unknown action.' }, 400);
      }
      return sendJSON(res, { ok: true });
    }
    if (pathname === '/api/aibots/try') {
      const message = String(body.message || '').trim();
      if (!message) return sendJSON(res, { error: 'invalid_payload' }, 400);
      const prompt = String(body.prompt || '');
      // Activity questions answer from "records", like the app's facts block.
      if (fixtures.aibots.activityAnswersEnabled && /usually|busiest|how much|how often|when/i.test(message)) {
        await new Promise(r => setTimeout(r, 900));
        const reply = /busiest/i.test(message) ? 'Evenings, mostly. Things usually kick off around 8:30 PM, and Fridays and Saturdays are the busiest.'
          : /\b(i|me|my)\b/i.test(message) ? 'You’ve been in voice on 11 of the last 30 days, about 23 hours in total. Usually from around 9 PM.'
          : `${(message.match(/is (\w+)/i) || [, 'They'])[1]}’s usually on around 8 PM, mostly on Fridays and Saturdays. Last seen in General last night.`;
        return sendJSON(res, { reply });
      }
      const style = /solving problems/i.test(prompt) ? 'Two things to check:\n1. SwiftBot can see the channel.\n2. The command is switched on in Commands.\nWhich server is it in?'
        : /playful/i.test(prompt) ? 'Bold of you to say hello after leaving me on read all week 💀'
        : /pirate/i.test(prompt) ? 'Arr, that be a fine question, matey!'
        : 'Ha, good one. Yeah, I can help with that.';
      await new Promise(r => setTimeout(r, 900));
      return sendJSON(res, { reply: style });
    }
    if (pathname === '/api/aibots/memory/clear') {
      const memory = fixtures.aibots.memory;
      memory.conversations = body.scopeID ? memory.conversations.filter(c => c.scopeID !== body.scopeID) : [];
      memory.totalMessages = memory.conversations.reduce((t, c) => t + c.messageCount, 0);
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
        userTimezones: ['userTimezones', 'mappings'],
        allowDMs: ['appleIntelligence', 'allowDMs'],
        useAIInGuildChannels: ['appleIntelligence', 'useAIInGuildChannels'],
        localAIDMReplyEnabled: ['appleIntelligence', 'localAIDMReplyEnabled'],
        localAISystemPrompt: ['appleIntelligence', 'localAISystemPrompt'],
        clusterMode: ['swiftMesh', 'mode'],
        clusterNodeName: ['swiftMesh', 'nodeName'],
        clusterLeaderAddress: ['swiftMesh', 'leaderAddress'],
        clusterLeaderPort: ['swiftMesh', 'leaderPort'],
        clusterListenPort: ['swiftMesh', 'listenPort'],
        clusterWorkerOffloadEnabled: ['swiftMesh', 'workerOffloadEnabled'],
        clusterOffloadAIReplies: ['swiftMesh', 'offloadAIReplies'],
        clusterOffloadWikiLookups: ['swiftMesh', 'offloadWikiLookups'],
        clusterAutoReclaimAfterHours: ['swiftMesh', 'autoReclaimAfterHours']
      };
      if ('aiActivityAnswersEnabled' in body) fixtures.aibots.activityAnswersEnabled = !!body.aiActivityAnswersEnabled;
      Object.entries(body).forEach(([key, value]) => {
        if (map[key]) config[map[key][0]][map[key][1]] = value;
      });
      // Keep /api/aibots in step, as the app's snapshot would be.
      const ai = fixtures.aibots;
      ai.allowDMs = config.appleIntelligence.allowDMs;
      ai.dmRepliesEnabled = config.appleIntelligence.localAIDMReplyEnabled;
      ai.guildMentionRepliesEnabled = config.appleIntelligence.useAIInGuildChannels;
      ai.systemPrompt = config.appleIntelligence.localAISystemPrompt;
      const preset = ai.personalities.find(p => p.prompt.trim() === ai.systemPrompt.trim());
      ai.isCustomPrompt = !preset;
      ai.personalities.forEach(p => { p.isSelected = p === preset; });
      console.log('[config]', JSON.stringify(body));
      return sendJSON(res, { ok: true });
    }

    if (pathname.startsWith('/api/wikibridge/')) {
      const find = (id) => wikibridge.sources.find((s) => s.id === id);
      switch (pathname) {
        case '/api/wikibridge/state':
          if (typeof body.enabled === 'boolean') wikibridge.enabled = body.enabled;
          if (typeof body.answersQuestions === 'boolean') wikibridge.answersQuestions = body.answersQuestions;
          break;
        case '/api/wikibridge/source/detect': {
          // Shaped like the Swift route; "example" exercises the not-a-wiki path.
          let host = '';
          try { host = new URL(String(body.baseURL || '')).host.replace(/^www\./, ''); } catch {}
          if (!host || host.includes('example')) return sendJSON(res, { error: 'not_mediawiki' }, 404);
          const word = host.split('.')[0];
          return sendJSON(res, { siteName: `${word.charAt(0).toUpperCase()}${word.slice(1)} Wiki`, apiPath: host.includes('thefinals') ? '/w/api.php' : '/api.php' });
        }
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
        case '/api/wikibridge/source/preview': {
          // Shaped like AppModel.previewAdminWebWikiSource; "nothing" exercises the no-result path.
          const query = String(body.query || '').trim();
          if (!query || /^nothing$/i.test(query)) return sendJSON(res, { error: 'no_result' }, 404);
          const stats = body.source?.formatting?.includeStatBlocks !== false;
          const compact = !!body.source?.formatting?.compactMode;
          const raw = stats
            ? [['Type', 'Assault Rifle'], ['Body Damage', '18'], ['Head Damage', '27'], ['Fire Rate', '600 RPM'], ['Dropoff Start', '25m'], ['Dropoff End', '35m'], ['Minimum Damage', '12'], ['Magazine', '35'], ['Short Reload', '1.9s']]
            : [['Class', 'Medium'], ['Released', 'Season 1']];
          const fields = raw.map(([name, value]) => ({ name, value, inline: true }));
          const description = compact
            ? `The ${query.toUpperCase()} is a fully automatic assault rifle.`
            : `The ${query.toUpperCase()} is a fully automatic assault rifle available to the Medium build. It trades a slower fire rate for strong per-shot damage and a generous magazine.`;
          const embed = {
            title: query.toUpperCase(), url: `${body.source?.baseURL || 'https://example.wiki'}/wiki/${encodeURIComponent(query)}`,
            description, color: 0x0c8f73, thumbnail: { url: 'https://placehold.co/160x160/png' },
            footer: { text: `${body.source?.name || 'Wiki'} • Lookup` }, fields
          };
          return sendJSON(res, { embed, fields: raw.map(([name, value]) => ({ key: name.toLowerCase().replace(/[^a-z0-9]/g, ''), name, value })) });
        }
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

// Signed in by default. Log out to see the sign-in page; "Continue with
// Discord" signs straight back in, standing in for the OAuth round trip.
let signedIn = true;
let signedInAs = 'admin'; // /auth/discord/login?as=member signs in as Gabe, a server member

const server = http.createServer(async (req, res) => {
  const pathname = decodeURIComponent(req.url.split('?')[0]);

  if (pathname === '/auth/logout') {
    signedIn = false;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end('{"ok":true}');
  }
  if (pathname === '/auth/discord/login') {
    signedIn = true;
    signedInAs = new URLSearchParams(req.url.split('?')[1] || '').get('as') === 'member' ? 'member' : 'admin';
    // A moment's pause so the button's "Opening Discord…" state shows.
    return setTimeout(() => { res.writeHead(302, { Location: '/' }); res.end(); }, 700);
  }

  if (pathname.startsWith('/api/')) {
    return handleAPI(req, res, pathname, new URLSearchParams(req.url.split('?')[1] || ''));
  }

  // The app serves its logo from the bundle's Resources folder, one level
  // above the admin files; mirror that so the preview isn't missing it.
  if (pathname === '/assets/SwiftBird3.png') {
    return fs.readFile(path.resolve(ROOT, '../SwiftBird3.png'), (error, data) => {
      if (error) { res.writeHead(404); return res.end('Not found'); }
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
      res.end(data);
    });
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
