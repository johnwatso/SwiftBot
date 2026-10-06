// Showcase mode for the admin WebUI preview: `SHOWCASE=1 node server.js`.
//
// Rewrites the dev fixtures into a tidy, healthy-looking server for website
// screenshots: plain "SwiftBot" branding, friendly members with avatars
// (borrowed from SwiftMiner's debug avatars, in showcase/avatars), no warning
// banners, and recordings with real game screenshots as thumbnails. The dev
// fixtures stay as they are, because their awkward cases (long names, broken
// avatars, failures) are what UI work needs to see.

const AVATAR = (name) => `/showcase/avatars/${name}.jpg`;
const minutesAgo = (m) => new Date(Date.now() - m * 60_000).toISOString();

// Steam app IDs for the clip thumbnails (/showcase/thumb picks a screenshot).
const STEAM_SCREENSHOT_APPS = {
  'THE FINALS': 2073850,
  'Deep Rock Galactic': 548430,
  'Apex Legends': 1172470,
  'Helldivers 2': 553850,
  'Counter-Strike 2': 730
};

module.exports = function applyShowcase(fixtures) {
  const { me, status, authOptions, overview, patchy, automationRules, media, config } = fixtures;

  Object.assign(me, { username: 'jonwatso', globalName: 'John', avatar: 'showcase', avatarURL: AVATAR('jonwatso') });
  Object.assign(status, { botUsername: 'SwiftBot', botAvatarURL: '/showcase/bot.png', uptimeText: '6d 4h' });
  Object.assign(authOptions, { botName: 'SwiftBot', botAvatarURL: '/showcase/bot.png' });
  config.swiftMesh.nodeName = 'Mac mini';
  overview.botInfo.uptime = status.uptimeText;
  overview.metrics.forEach((m) => {
    if (m.title === 'Bot Status') m.subtitle = status.uptimeText;
    if (m.title === 'Users In Voice') m.value = '6';
    if (m.title === 'Commands Run') m.value = '128';
  });

  overview.activeVoice = [
    ['412378964087275541', 'John', 'jonwatso', 'General Voice', 96],
    ['280129381292318720', 'Sam', 'sam', 'General Voice', 74],
    ['280129381292318721', 'Alex', 'alex', 'General Voice', 51],
    ['280129381292318722', 'Jordan', 'jordan', 'General Voice', 12],
    ['280129381292318723', 'Riley', 'riley', 'Stream Room', 38],
    ['280129381292318724', 'Mia', 'mia', 'Stream Room', 6]
  ].map(([userId, username, avatar, channelName, mins]) => ({
    userId, username, channelName, serverName: 'Swift Lounge',
    joinedText: `Joined ${mins}m ago`, joinedAt: minutesAgo(mins), avatarURL: AVATAR(avatar)
  }));
  overview.health.state = 'healthy';
  overview.health.title = 'Nominal';
  overview.health.attention = [];
  overview.health.activity = [
    ['User Joined Voice', 'Mia joined Stream Room', 'audio-waveform', 'join', 6],
    ['Command Executed', 'Sam ran /rank', 'terminal', 'command', 9],
    ['Patchy Posted', 'NVIDIA driver 581.42 → #announcements', 'hammer', 'patchy', 21],
    ['Command Executed', 'Riley ran /music Dawn Beyond', 'terminal', 'command', 34],
    ['User Joined Voice', 'Riley joined Stream Room', 'audio-waveform', 'join', 38]
  ].map(([title, detail, icon, tone, mins], i) => ({ id: `s${i}`, timestamp: minutesAgo(mins), title, detail, icon, tone }));

  // A failed target puts a warning dot on the Patchy sidebar item.
  patchy.targets.forEach((t) => {
    if (/^Failed/.test(t.lastStatus)) t.lastStatus = 'Released SwiftBot 2.0';
    if (t.source === 'Apple') Object.assign(t, { isEnabled: true, lastStatus: 'macOS 26.1 posted', lastCheckedAt: minutesAgo(48), lastRunAt: minutesAgo(48) });
  });

  // More (and all switched on) rules, so the lists look lived-in.
  const step = (rule, extra) => ({ ...rule, steps: [{ ...rule.steps[0], ...extra }] });
  const [welcome, sleepy] = automationRules.automation;
  automationRules.automation = [
    welcome,
    step({ ...sleepy, id: 'a1a1a1a1-0000-4000-8000-000000000003', name: 'Stream starting ping', enabled: true, trigger: { kind: 'userJoinedVoice' } }, { content: '🔴 {username} just went live in {channel}!' }),
    step({ ...sleepy, id: 'a1a1a1a1-0000-4000-8000-000000000004', name: 'Patch notes thread', enabled: true }, { content: 'Discuss the patch here 👇' }),
    { ...sleepy, name: 'Good night react', enabled: true }
  ];
  const [blockLinks] = automationRules.moderation;
  automationRules.moderation = [
    blockLinks,
    step({ ...blockLinks, id: 'b2b2b2b2-0000-4000-8000-000000000002', name: 'Hold new-account invites' }, {}),
    step({ ...blockLinks, id: 'b2b2b2b2-0000-4000-8000-000000000003', name: 'Slow down mention spam' }, {})
  ];

  // Minecraft isn't on Steam, so swap it for a game we can show screenshots of.
  media.items.forEach((item, i) => {
    if (item.gameName === 'Minecraft') {
      item.gameName = 'Deep Rock Galactic';
      item.fileName = item.fileName.replace('Minecraft', 'DeepRockGalactic');
      item.relativePath = item.relativePath.replace('Minecraft', 'Deep Rock Galactic');
    }
    item.thumbnailURL = `/showcase/thumb?game=${encodeURIComponent(item.gameName)}&n=${i}`;
  });
  media.games = [...new Set(media.items.map((m) => m.gameName))].sort();
};

// GET /showcase/thumb?game=…&n=… → a full-size Steam screenshot, cached.
const shotCache = new Map();
module.exports.sendThumb = function sendThumb(res, game, n) {
  const appID = STEAM_SCREENSHOT_APPS[game];
  const https = require('https');
  const fail = () => { res.writeHead(404); res.end(); };
  const get = (url) => new Promise((resolve, reject) => {
    https.get(url, (up) => {
      if (up.statusCode !== 200) { up.resume(); return reject(new Error(String(up.statusCode))); }
      const chunks = [];
      up.on('data', (c) => chunks.push(c));
      up.on('end', () => resolve(Buffer.concat(chunks)));
    }).on('error', reject);
  });
  if (!appID) return fail();
  const key = `${appID}:${n}`;
  const send = (buf) => { res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'private, max-age=86400' }); res.end(buf); };
  if (shotCache.has(key)) return send(shotCache.get(key));
  get(`https://store.steampowered.com/api/appdetails?appids=${appID}&filters=screenshots`)
    .then((buf) => {
      const shots = JSON.parse(buf.toString())[appID]?.data?.screenshots || [];
      if (!shots.length) throw new Error('no screenshots');
      return get(shots[Number(n) % shots.length].path_full);
    })
    .then((img) => { shotCache.set(key, img); send(img); })
    .catch(fail);
};
