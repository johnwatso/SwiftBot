// Fake Discord/runtime data for the admin WebUI preview server.
// Nothing here talks to Discord — edit freely to exercise different UI states.

const servers = [
  { id: '1001', name: 'Swift Lounge' },
  { id: '1002', name: 'Dev Bunker' }
];

const voiceChannelsByServer = {
  '1001': [
    { id: 'v100', name: 'General Voice' },
    { id: 'v101', name: 'Stream Room' },
    { id: 'v102', name: 'AFK' }
  ],
  '1002': [
    { id: 'v200', name: 'Standup' },
    { id: 'v201', name: 'Pairing' }
  ]
};

const textChannelsByServer = {
  // Deliberately large: real servers have hundreds of text channels, and the
  // picker has to stay usable at that size.
  '1001': [
    { id: 't100', name: 'general' },
    { id: 't101', name: 'announcements' },
    { id: 't102', name: 'stream-chat' },
    { id: 't103', name: 'memes' },
    ...Array.from({ length: 240 }, (_, i) => ({
      id: `t2${String(i).padStart(3, '0')}`,
      name: `${['team', 'project', 'squad', 'guild', 'raid'][i % 5]}-${['alpha', 'bravo', 'delta', 'echo'][i % 4]}-${i}`
    }))
  ],
  '1002': [
    { id: 't200', name: 'dev-log' },
    { id: 't201', name: 'ci-alerts' }
  ]
};

// Mirrors AdminWebSimpleOption rows built from AVSpeechSynthesisVoice.speechVoices().
const installedVoices = [
  { id: 'com.apple.voice.premium.en-GB.Ryan', name: 'Ryan — en-GB (Premium)' },
  { id: 'com.apple.voice.enhanced.en-GB.Serena', name: 'Serena — en-GB (Enhanced)' },
  { id: 'com.apple.voice.compact.en-US.Samantha', name: 'Samantha — en-US (Default)' },
  { id: 'com.apple.voice.enhanced.en-US.Evan', name: 'Evan — en-US (Enhanced)' }
];

// Shape matches AnnouncerVoiceChannelConfig in Sources/SwiftBot/Models/VoiceSettings.swift.
const announcerConfigs = [
  {
    id: 'cfg-lounge',
    name: 'Lounge Announcer',
    voiceChannelID: 'v100',
    voiceChannelName: 'General Voice',
    symbol: 'speaker.wave.2.bubble.fill',
    tint: 'purple',
    autoJoin: true,
    introduceOnManualJoin: true,
    autoJoinOnStream: false,
    introduceOnStreamJoin: false,
    readVoiceChannelChat: true,
    ignoreWebhooks: false,
    skipBots: true,
    ignoreLinks: true,
    summariseLong: false,
    keepShort: false,
    smartShortenWithAppleIntelligence: false,
    ignoreEmojiSpam: true,
    suppressRepeatedSpeakerNames: true,
    preferredVoiceIdentifier: '',
    connectionMode: 'fixed',
    connectionMinutes: 20,
    emptyChannelGraceSeconds: 30,
    textChannels: ['general', 'announcements'],
    enabled: true
  },
  {
    id: 'cfg-stream',
    name: 'Stream Room',
    voiceChannelID: 'v101',
    voiceChannelName: 'Stream Room',
    symbol: 'radio',
    tint: 'orange',
    autoJoin: false,
    introduceOnManualJoin: false,
    autoJoinOnStream: true,
    introduceOnStreamJoin: true,
    readVoiceChannelChat: true,
    ignoreWebhooks: true,
    skipBots: false,
    ignoreLinks: true,
    summariseLong: true,
    keepShort: true,
    smartShortenWithAppleIntelligence: true,
    ignoreEmojiSpam: false,
    suppressRepeatedSpeakerNames: false,
    preferredVoiceIdentifier: 'com.apple.voice.premium.en-GB.Ryan',
    connectionMode: 'untilEmpty',
    connectionMinutes: 20,
    emptyChannelGraceSeconds: 60,
    textChannels: ['stream-chat'],
    enabled: false
  }
];

// Mirrors AdminWebAnnouncerPayload.
const announcer = {
  configs: announcerConfigs,
  servers,
  textChannelsByServer,
  voiceChannelsByServer,
  guildID: '1001',
  voiceChannelID: 'v100',
  watchedTextChannelID: 't100',
  preferredVoiceIdentifier: 'com.apple.voice.premium.en-GB.Ryan',
  textChannelSourceEnabled: true,
  autoConnect: true,
  installedVoices,
  // Mirrors AdminWebAnnouncerLiveState — flip these to preview other states.
  liveState: {
    isConnected: true,
    connectionLabel: 'Connected',
    phaseLabel: 'Sending',
    listening: 'Listening in General Voice',
    monitoredFeeds: '#General Voice, #general, #announcements',
    queueDepth: 2,
    queueLabel: '2 announcements waiting',
    manualHold: null,
    recovery: null
  }
};

// Only the fields the dashboard shell reads on boot — enough to get past
// bootstrap() and land on the Announcer view.
const me = {
  id: 'preview-user',
  username: 'Preview Admin',
  csrfToken: 'preview-csrf-token',
  avatarURL: '',
  isLocal: true
};

const overview = {
  // Mirrors AppModel.adminWebOverviewSnapshot() — same titles and shape.
  metrics: [
    { title: 'Bot Status', value: 'Running', subtitle: '3h 12m' },
    { title: 'Servers Connected', value: '2', subtitle: 'Standalone' },
    { title: 'Users In Voice', value: '0', subtitle: 'users right now' },
    { title: 'Commands Run', value: '14', subtitle: 'this session' },
    { title: 'New Recordings', value: '3', subtitle: 'last 24 hours' },
    { title: 'Lookup Status', value: 'Enabled', subtitle: '2 sources' },
    { title: 'Patchy Monitoring', value: 'Monitoring On', subtitle: '3/4 targets' },
    { title: 'Active Actions', value: '5', subtitle: '7 total rules' },
    { title: 'AI', value: 'Apple Intelligence online', subtitle: 'DM replies enabled' }
  ],
  cluster: { connectedNodes: 1, leader: 'this node', mode: 'Standalone' },
  botInfo: { uptime: '3h 12m', errors: 0, state: 'Connected' },
  recentVoice: [
    { description: 'Joined General Voice', timeText: '2m ago' },
    { description: 'Left Stream Room', timeText: '18m ago' }
  ],
  recentCommands: [{ title: '/announce join', ok: true, timeText: '2m ago' }],
  activeVoice: [],
  // Mirrors AdminWebOverviewHealthPayload (built from OverviewHealthReport).
  health: {
    state: 'warning',
    title: 'Needs Review',
    tiles: [
      { id: 'gateway-latency', title: 'Gateway Heartbeat', value: '42 ms', detail: 'Last event: MESSAGE_CREATE', icon: 'radio-tower', state: 'healthy' },
      { id: 'cluster-role', title: 'Cluster Role', value: 'Standalone', detail: 'Preview Mac', icon: 'network', state: 'healthy' },
      { id: 'last-sync', title: 'Last Sync', value: '12s ago', detail: 'Voice state observed', icon: 'refresh-cw', state: 'healthy' },
      { id: 'memory', title: 'Memory', value: '184 MB', detail: 'Average resident footprint', icon: 'memory-stick', state: 'neutral' },
      { id: 'discord', title: 'Discord Connectivity', value: 'REST OK', detail: '48 REST requests remaining', icon: 'cloud', state: 'healthy' },
      { id: 'throughput', title: 'Event Throughput', value: '6.4/min', detail: '412 retained runtime events', icon: 'activity', state: 'healthy' },
      { id: 'rate-limit', title: 'Rate Limit', value: '48 rem.', detail: 'Per-route headroom', icon: 'gauge', state: 'healthy' },
      { id: 'intents', title: 'Intents', value: 'Accepted', detail: 'Gateway intent negotiation', icon: 'list-checks', state: 'healthy' }
    ],
    attention: [
      { id: 'failed-commands', title: 'Command failures today', detail: '1 command failed and may need review.', severity: 'warning', label: 'Review' }
    ],
    activity: [
      { id: 'a1', timestamp: new Date(Date.now() - 45_000).toISOString(), title: 'User Joined Voice', detail: 'Sam joined General Voice', icon: 'audio-waveform', tone: 'join' },
      { id: 'a2', timestamp: new Date(Date.now() - 120_000).toISOString(), title: 'Command Executed', detail: 'Sam ran /announce join', icon: 'terminal', tone: 'command' },
      { id: 'a3', timestamp: new Date(Date.now() - 600_000).toISOString(), title: 'Command Failed', detail: 'Alex ran /wiki finals', icon: 'terminal', tone: 'commandFailed' },
      { id: 'a4', timestamp: new Date(Date.now() - 1_080_000).toISOString(), title: 'User Left Voice', detail: 'Alex left Stream Room', icon: 'audio-waveform', tone: 'leave' },
      { id: 'a5', timestamp: new Date(Date.now() - 1_800_000).toISOString(), title: 'Patchy Checked', detail: '3 targets monitored', icon: 'hammer', tone: 'patchy' }
    ]
  }
};

const status = {
  botUsername: 'SwiftBot (Preview)',
  botAvatarURL: '',
  state: 'Connected'
};

const analytics = {
  generatedAt: new Date().toISOString(),
  metrics: [],
  dailyActivity: [],
  peakActivityLabel: 'Preview mode'
};

const rewind = {
  generatedAt: new Date().toISOString(),
  isEnabled: true,
  retainsContent: true,
  retentionDays: 0,
  messageCount: 182441,
  diskBytes: 15_204_352,
  earliestDay: '2026-01-01',
  latestDay: '2026-09-03',
  guilds: [
    {
      id: '1',
      name: 'Preview Server',
      years: [2026, 2025],
      year: 2026,
      totalMessages: 182441,
      totalWords: 1_204_889,
      activeDays: 246,
      busiestDay: '2026-03-14',
      peakHour: '9pm',
      topUsers: [
        { label: 'john', count: 41203 },
        { label: 'max', count: 30112 },
        { label: 'gabe', count: 18994 }
      ],
      topWords: [
        { label: 'gg', count: 4821 },
        { label: 'lol', count: 3902 },
        { label: 'actually', count: 1544 }
      ],
      topPhrases: [
        { label: 'gg guys', count: 812 },
        { label: 'how often is', count: 96 }
      ],
      topEmoji: [
        { label: '😂', count: 5210 },
        { label: '🎉', count: 1044 }
      ]
    }
  ]
};

const authOptions = { discordEnabled: false, localEnabled: true, botName: 'SwiftBot (Preview)', botAvatarURL: '' };

// ---------------------------------------------------------------------------
// Fixtures for the remaining views. Shapes mirror the AdminWeb*Payload structs
// in AdminWebServer.swift; lists whose element types are deeply nested
// (automation rules, Sweep policies) are left empty so the views render their
// empty states.
// ---------------------------------------------------------------------------

const minutesAgo = (m) => new Date(Date.now() - m * 60_000).toISOString();
const textChannels = textChannelsByServer['1001'].map(c => ({ id: c.id, name: c.name }));
const roleOptions = [
  { id: 'r1', name: 'Moderators' },
  { id: 'r2', name: 'Patch Watchers' },
  { id: 'r3', name: 'Members' }
];
const serverOptions = servers.map(s => ({ id: s.id, name: s.name }));
const textByServer = Object.fromEntries(Object.entries(textChannelsByServer).map(([k, v]) => [k, v.map(c => ({ id: c.id, name: c.name }))]));

Object.assign(status, {
  botStatus: 'running',
  connectedServerCount: 2,
  gatewayEventCount: 18342,
  uptimeText: '3h 12m',
  webUIEnabled: true,
  webUIBaseURL: 'http://127.0.0.1:4179',
  clusterMode: 'standalone',
  runtimeState: 'running',
  isFailoverManagedNode: false
});

Object.assign(analytics, {
  peakActivityLabel: 'Most active around 9pm',
  metrics: [
    { id: 'sessions', title: 'Voice Sessions', value: '128', detail: 'last 7 days', trend: '+12%', tone: 'positive' },
    { id: 'hours', title: 'Voice Hours', value: '96h', detail: 'last 7 days', trend: '+4%', tone: 'positive' },
    { id: 'commands', title: 'Commands', value: '342', detail: 'last 7 days', trend: '-3%', tone: 'neutral' },
    { id: 'members', title: 'Active Members', value: '27', detail: 'last 7 days', trend: '+2', tone: 'positive' }
  ],
  dailyActivity: Array.from({ length: 7 }, (_, i) => ({
    date: new Date(Date.now() - (6 - i) * 86_400_000).toISOString(),
    label: ['Fri', 'Sat', 'Sun', 'Mon', 'Tue', 'Wed', 'Thu'][i],
    count: [12, 24, 31, 9, 14, 18, 20][i]
  })),
  hourlyActivity: Array.from({ length: 24 }, (_, h) => ({ hour: h, label: `${h}:00`, count: Math.round(10 + 30 * Math.max(0, Math.sin((h - 12) / 4))) })),
  topUsers: [
    { id: 'u1', username: 'sam', initials: 'SA', totalTime: '14h 2m', activityShare: 32, isActive: true },
    { id: 'u2', username: 'alex', initials: 'AL', totalTime: '9h 41m', activityShare: 22, isActive: false },
    { id: 'u3', username: 'jordan', initials: 'JO', totalTime: '6h 5m', activityShare: 14, isActive: false }
  ],
  feed: [
    { id: 'f1', timestamp: minutesAgo(3), title: 'Voice session ended', detail: 'sam · 1h 12m in General Voice', category: 'voice', tone: 'neutral' },
    { id: 'f2', timestamp: minutesAgo(25), title: 'Command spike', detail: '/announce used 14 times this hour', category: 'commands', tone: 'positive' }
  ],
  health: { state: 'healthy', detail: 'Gateway stable', websocketLatencyMs: 42, reconnectCount: 0, activeTasks: 6, eventQueueDepth: 2, eventQueueLoad: 0.08, memoryText: '184 MB' },
  insights: [
    { title: 'Weekend peak', body: 'Voice activity is 2.3× higher on Saturdays.', tone: 'positive' }
  ]
});

const config = {
  commands: { enabled: true, prefixEnabled: true, slashEnabled: true, bugTrackingEnabled: false, prefix: '!' },
  appleIntelligence: { localAIDMReplyEnabled: true, useAIInGuildChannels: false, allowDMs: true, localAISystemPrompt: 'You are SwiftBot, a friendly Discord assistant.' },
  wikiBridge: { enabled: true, enabledSources: 2, totalSources: 2 },
  patchy: { monitoringEnabled: true, enabledTargets: 3, totalTargets: 4 },
  swiftMesh: { mode: 'standalone', nodeName: 'Preview Mac', leaderAddress: '', leaderPort: 38787, listenPort: 38787, workerOffloadEnabled: false, offloadAIReplies: false, offloadWikiLookups: false, autoReclaimAfterHours: 6 },
  general: { autoStart: true, webUIEnabled: true, webUIBaseURL: 'http://127.0.0.1:4179' },
  userTimezones: {
    mappings: { '412378964087275541': 'Pacific/Auckland', '280129381292318720': 'Pacific/Auckland', '512391234123412345': 'Europe/London' },
    members: [
      { id: '412378964087275541', name: 'jonwatso', username: null },
    { id: '280129381292318720', name: 'Sam', username: 'samthegreat' },
      { id: '280129381292318721', name: 'Alex', username: null },
      { id: '280129381292318722', name: 'Jordan', username: 'jordan_ttv' }
    ]
  },
  swiftMiner: { enabled: false, paired: false }
};

const commandItem = (id, name, usage, description, category, surface, extra = {}) =>
  ({ id, name, usage, description, category, surface, aliases: [], adminOnly: false, enabled: true, ...extra });
const commands = {
  commandsEnabled: true,
  prefixCommandsEnabled: true,
  slashCommandsEnabled: true,
  // Mirrors allSlashCommandDefinitions() + SlashCommandGroup in the app.
  items: [
    ['help', '/help [command:<value>]', 'Show help for SwiftBot', 'General'],
    ['ping', '/ping', 'Check if bot is alive', 'General'],
    ['userinfo', '/userinfo', 'Show user info', 'General'],
    ['weekly', '/weekly', 'Show weekly summary', 'General'],
    ['roll', '/roll notation:<value>', 'Roll dice, example: 2d6', 'Utilities & AI'],
    ['8ball', '/8ball question:<value>', 'Ask the magic 8-ball', 'Utilities & AI', { enabled: false }],
    ['poll', '/poll question:<value>', 'Create a simple poll prompt', 'Utilities & AI'],
    ['randomteams', '/randomteams teams:<value> [max_size:<value>]', 'Suggest balanced teams from your current voice channel', 'Utilities & AI'],
    ['image', '/image prompt:<value>', 'Generate an image with OpenAI', 'Utilities & AI', { enabled: false }],
    ['music', '/music [help:<value>] [query:<value>] [title:<value>] [artist:<value>]', 'Search music and get Apple/Spotify/YouTube links', 'Utilities & AI'],
    ['playlist', '/playlist url:<value>', 'Import a playlist URL into a thread with per-track links', 'Utilities & AI'],
    ['timestamp', '/timestamp time:<value>', 'Convert a natural-language time into a Discord timestamp', 'Utilities & AI'],
    ['announce', '/announce action:<value>', 'Control your configured Announcer voice channel', 'Utilities & AI'],
    ['rewind', '/rewind phrase:<value>', 'Count how often a word or phrase has been used', 'Utilities & AI'],
    ['finals', '/finals query:<value>', 'Search THE FINALS wiki', 'Utilities & AI'],
    ['debug', '/debug', 'Admin diagnostics', 'Moderation', { adminOnly: true }],
    ['notifystatus', '/notifystatus', 'Show notification config status', 'Moderation'],
    ['setchannel', '/setchannel', 'Set this channel as notifications channel', 'Moderation'],
    ['ignorechannel', '/ignorechannel action:<value> [channel:<value>]', 'Manage ignored voice channels', 'Moderation'],
    ['sweep', '/sweep action:<value>', 'Run, preview, or pause Sweep rules', 'Moderation'],
    ['cluster', '/cluster [action:<value>]', 'Cluster status/probe/test', 'Infrastructure'],
    ['miner', '/miner [action:<value>]', 'Check or set up your SwiftMiner drops miner', 'Infrastructure', { enabled: false }],
    ['compare', '/compare first:<value> second:<value>', 'Compare two THE FINALS weapons', 'Gaming'],
    ['meta', '/meta', 'Fetch current THE FINALS meta from Skycoach', 'Gaming'],
    ['steam', '/steam game:<value>', 'Search Steam for game info and player counts', 'Gaming']
  ].map(([name, usage, description, category, extra]) => commandItem(`slash-${name}`, name, usage, description, category, 'slash', extra)),
  musicLinkWatch: { isEnabled: false, channelIDs: [], servers: serverOptions, textChannelsByServer: textByServer }
};

const serverContext = { guildName: 'Preview Server', guildId: '1001', textChannels, voiceChannels: voiceChannelsByServer['1001'].map(c => ({ id: c.id, name: c.name })), roles: roleOptions };
// Rule shape mirrors autoBlankRule() in index.html (Automations.Rule).
const rule = (id, name, category, trigger, step, enabled = true) =>
  ({ id, name, enabled, category, trigger: { kind: trigger }, filterLogic: 'all', filters: [], steps: [{ id: `${id.slice(0, 24)}00000000000a`, ...step }] });
const automationRules = {
  automation: [
    rule('a1a1a1a1-0000-4000-8000-000000000001', 'Welcome to voice', 'automation', 'userJoinedVoice', { kind: 'sendMessage', sendTarget: 'replyToTrigger', content: 'Hey {username}!' }),
    rule('a1a1a1a1-0000-4000-8000-000000000002', 'Sleepy react', 'automation', 'messageCreated', { kind: 'sendMessage', sendTarget: 'replyToTrigger', content: '😴' }, false)
  ],
  moderation: [
    rule('b2b2b2b2-0000-4000-8000-000000000001', 'Block spam links', 'moderation', 'messageCreated', { kind: 'modifyMessage', messageOp: 'delete' })
  ]
};
// Templates are read from the Swift catalog so the preview always shows the
// real list. Rules are simplified to the trigger plus the first step's kind;
// the real server sends the full rule.
const automationTemplates = (() => {
  const fs = require('fs');
  const path = require('path');
  const source = fs.readFileSync(path.resolve(__dirname, '../../Sources/SwiftBot/Models/AutomationTemplates.swift'), 'utf8');
  const catalogs = { automation: [], moderation: [] };
  const blocks = source.split('AutomationTemplate(\n').slice(1);
  blocks.forEach((block, index) => {
    const field = (name) => (block.match(new RegExp(`${name}: "([^"]*)"`)) || [])[1] || '';
    const category = /category: \.moderation/.test(block) ? 'moderation' : 'automation';
    const trigger = (block.match(/Trigger\(kind: \.(\w+)/) || [])[1] || 'messageCreated';
    const stepKind = (block.match(/Step\(\s*kind: \.(\w+)/) || [])[1] || 'log';
    const id = field('id');
    if (!id) return;
    catalogs[category].push({
      id, title: field('title'), subtitle: field('subtitle'), symbol: field('symbol'),
      tint: (block.match(/tint: \.(\w+)/) || [])[1] || 'blue',
      rule: rule(`c3c3c3c3-0000-4000-8000-${String(index).padStart(12, '0')}`, field('title'), category, trigger, { kind: stepKind })
    });
  });
  return catalogs;
})();
const automations = (category, rules = automationRules[category] || []) => ({
  category,
  rules,
  templates: automationTemplates[category] || [],
  serverContext,
  metrics: { total: rules.length, enabled: rules.filter(r => r.enabled).length, triggerKinds: new Set(rules.map(r => r.trigger.kind)).size }
});

const welcomeFlow = {
  settings: {
    publicWelcomeEnabled: true, publicChannelId: 't100', publicMessageFormat: 'plainText',
    publicMessageTemplate: '👋 Welcome {username} to **{server}**!', publicMessageTemplatePool: [],
    publicEmbedTitleTemplate: 'Welcome to {server}', publicEmbedFooterTemplate: 'Member #{memberCount}',
    publicEmbedColor: 5793266, publicEmbedShowAvatar: true, publicEmbedShowAuthor: false,
    dmWelcomeEnabled: false, dmMessageTemplate: 'Hey {username}! Glad you are here.', dmFallbackToChannelEnabled: true,
    dmFallbackTemplate: '👋 {userMention} — I tried to send you a welcome DM but your DMs are closed.',
    autoRoleEnabled: true, autoRoleId: 'r3', nextStepRules: [], burstThreshold: 10, skipBots: true,
    minAccountAgeDays: 0, accountAgeAction: 'skipWelcome', modAlertChannelId: '',
    goodbyeEnabled: false, goodbyeChannelId: '', goodbyeMessageFormat: 'plainText',
    goodbyeMessageTemplate: '👋 {username} just left **{server}**.', goodbyeEmbedTitleTemplate: 'Goodbye from {server}',
    goodbyeEmbedFooterTemplate: '{memberCount} members remaining', goodbyeEmbedColor: 14633293
  },
  serverContext,
  metrics: { activeRules: 1, inviteRules: 0, safetyEnabled: true }
};

const patchyTarget = (id, source, extra) => ({
  id, isEnabled: true, source, steamAppID: '2073850', useSteamIcon: true, githubRepo: '', githubBranch: '',
  githubWatchAllCommits: false, githubBranchMode: 'main', appleProduct: 'macOS', appleIncludeBetas: false,
  swiftMinerGameName: 'The Finals', pollingIntervalMinutes: 60, embedColorHex: '', summarizeWithAppleIntelligence: false,
  serverId: '1001', channelId: 't101', roleIDs: [], lastCheckedAt: minutesAgo(12), lastRunAt: minutesAgo(12),
  lastStatus: 'Up to date', ...extra
});
const patchy = {
  monitoringEnabled: true, showDebug: false, isCycleRunning: false, lastCycleAt: minutesAgo(12),
  sourceKinds: ['NVIDIA', 'AMD', 'Intel Arc', 'Apple', 'Steam', 'GitHub', 'SwiftMiner'],
  targets: [
    patchyTarget('11111111-1111-1111-1111-111111111111', 'Steam', { lastStatus: 'Delivered patch 1.4.2' }),
    patchyTarget('22222222-2222-2222-2222-222222222222', 'NVIDIA', { lastStatus: 'New driver 572.16 posted' }),
    patchyTarget('33333333-3333-3333-3333-333333333333', 'GitHub', { githubRepo: 'johnwatso/SwiftBot', lastStatus: 'Failed: rate limited' }),
    patchyTarget('44444444-4444-4444-4444-444444444444', 'Apple', { isEnabled: false, lastStatus: 'Never checked', lastCheckedAt: null, lastRunAt: null })
  ],
  servers: serverOptions, textChannelsByServer: textByServer, rolesByServer: { '1001': roleOptions, '1002': [] },
  steamAppNames: { '2073850': 'THE FINALS' }, isFailoverManagedNode: false, botStatus: 'running', debugLogs: []
};

const aibots = {
  online: true, replyScope: 'mentions', dmRepliesEnabled: true, guildMentionRepliesEnabled: true, allowDMs: true,
  systemPrompt: 'You are SwiftBot, a friendly Discord assistant.', selectedPersonalityID: 'friendly', isFailoverManagedNode: false,
  personalities: [
    { id: 'friendly', title: 'Friendly', summary: 'Warm and helpful', description: 'Upbeat, concise answers.', preview: 'Happy to help! 😊', prompt: '', icon: 'smile', tint: 'blue', isSelected: true },
    { id: 'dry', title: 'Deadpan', summary: 'Dry wit', description: 'Short, sardonic replies.', preview: 'Sure. Fascinating.', prompt: '', icon: 'meh', tint: 'gray', isSelected: false },
    { id: 'pirate', title: 'Pirate', summary: 'Arr', description: 'Talks like a pirate.', preview: 'Ahoy, matey!', prompt: '', icon: 'anchor', tint: 'orange', isSelected: false }
  ],
  capabilities: [
    { id: 'dm', title: 'DM Replies', description: 'Answer direct messages.', icon: 'message-circle', tint: 'blue', status: 'active' },
    { id: 'mentions', title: 'Mention Replies', description: 'Reply when mentioned in servers.', icon: 'at-sign', tint: 'purple', status: 'active' },
    { id: 'summaries', title: 'Patch Summaries', description: 'Summarise patch notes for Patchy.', icon: 'sparkles', tint: 'orange', status: 'ready' }
  ],
  memory: { totalMessages: 214, conversations: [
    { id: 'c1', scopeID: 'u1', scopeType: 'dm', title: 'DM with sam', messageCount: 120 },
    { id: 'c2', scopeID: 't100', scopeType: 'channel', title: '#general', messageCount: 94 }
  ] }
};

const wikiSource = (id, name, baseURL, isPrimary) => ({
  id, name, baseURL, apiPath: '/api.php', searchScope: '', enabled: true, isPrimary,
  commands: [{ id: `${id.slice(0, 24)}000000000001`, trigger: `/${name.toLowerCase().split(' ')[0]}`, endpoint: 'search', description: `Search ${name}`, enabled: true }],
  formatting: { includeStatBlocks: true, useEmbeds: true, compactMode: false, hiddenEmbedFields: [] },
  parsingRules: isPrimary ? [{ id: `${id.slice(0, 24)}000000000002`, pageType: 'weapon', templateName: 'Weapon' }] : [],
  lastLookupAt: minutesAgo(40), lastStatus: 'OK'
});
const wikibridge = {
  enabled: true,
  sources: [
    wikiSource('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Finals Wiki', 'https://thefinals.wiki', true),
    wikiSource('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Minecraft Wiki', 'https://minecraft.wiki', false)
  ]
};

// Shapes mirror SweepPolicy / SweepRunReport / SweepSuggestion (SweepView.swift);
// SweepSchedule uses Swift's synthesized enum coding, e.g. { interval: { minutes: 60 } }.
const sweepAction = (i, kind, mode, preview, reason, authorName, isBot) =>
  ({ id: `d0d0d0d0-0000-4000-8000-${String(i).padStart(12, '0')}`, kind, mode, messageID: `m${i}`, preview, reason, authorName, isBot });
const sweepReport = (id, policyID, policyName, minutes, extra) => ({
  id, policyID, policyName, startedAt: minutesAgo(minutes), durationMS: 840, scanned: 120, matched: 34, executed: 31, suppressed: 3,
  dryRun: false, error: null, summary: null,
  actions: [
    sweepAction(1, 'delete', 'destructive', 'NVIDIA driver 572.16 is out!', 'Bot message older than 48h', 'Patchy', true),
    sweepAction(2, 'delete', 'destructive', 'NVIDIA driver 572.16 is out!', 'Duplicate of a newer message', 'Patchy', true),
    sweepAction(3, 'skip', 'virtual', 'Server rules — read before posting', 'Pinned message protected', 'sam', false),
    sweepAction(4, 'skip', 'virtual', 'gg everyone 🎉', 'Has reactions — protected', 'alex', false)
  ],
  ...extra
});
const sweepPolicy = (id, name, channelID, channelName, strategies, schedule, extra = {}) => ({
  id, name, guildID: '1001', guildName: 'Swift Lounge', channelID, channelName, strategies, schedule,
  safety: { maxMessagesPerRun: 200, dryRunOnly: false, minMessageAgeMinutes: 5, protectPinned: true, protectReacted: true },
  notice: { isEnabled: false, template: ':swiftbird: Swiftbot is managing this channel — it is cleared {time} {frequency}.', showVoiceAverages: false, pinnedMessageID: null },
  weeklyMVP: { isEnabled: false, weekday: 2, hour: 20, template: "🏆 This week's MVP is {winner} with {duration} this week!", lastPostedWeekKey: null, pinnedMessageID: null },
  isEnabled: true, createdAt: minutesAgo(20000), updatedAt: minutesAgo(3000), lastRunAt: minutesAgo(95), nextRunAt: minutesAgo(-25),
  ...extra
});
const sweepPolicies = [
  sweepPolicy('e1e1e1e1-0000-4000-8000-000000000001', 'Tidy patch notes', 't101', 'announcements',
    [{ id: 'e1e1e1e1-0000-4000-8000-0000000000a1', kind: 'reduceNoise', ageHours: 48, keepCount: 1, fromBotsOnly: true }],
    { interval: { minutes: 120 } }),
  sweepPolicy('e1e1e1e1-0000-4000-8000-000000000002', 'Weekly voice-chat reset', 't100', 'general',
    [{ id: 'e1e1e1e1-0000-4000-8000-0000000000a2', kind: 'keepLatest', ageHours: 24, keepCount: 20, fromBotsOnly: false }],
    { daily: { hour: 4 } }, { isEnabled: false, lastRunAt: null, nextRunAt: null })
];
const sweep = {
  globalPaused: false, state: 'Active', stateTone: 'success', nextRunDescription: 'Next run in 25m',
  enabledPolicyCount: 1, totalPolicyCount: 2, messagesTodayCount: 31, suppressedTodayCount: 3, summariesThisWeekCount: 0,
  policies: sweepPolicies,
  recentReports: [
    sweepReport('f2f2f2f2-0000-4000-8000-000000000001', sweepPolicies[0].id, 'Tidy patch notes', 95),
    sweepReport('f2f2f2f2-0000-4000-8000-000000000002', sweepPolicies[0].id, 'Tidy patch notes', 215, { executed: 12, matched: 14, suppressed: 2 }),
    sweepReport('f2f2f2f2-0000-4000-8000-000000000003', sweepPolicies[1].id, 'Weekly voice-chat reset', 1500, { error: 'Missing Manage Messages permission in #general', executed: 0, matched: 0, actions: [] })
  ],
  suggestions: [{
    id: 'a7a7a7a7-0000-4000-8000-000000000001', guildID: '1001', guildName: 'Swift Lounge', channelID: 't102', channelName: 'stream-chat',
    strategyKind: 'deduplicate', title: 'Remove duplicate clip links in #stream-chat',
    rationale: '42 messages in the last week repeat an earlier link. Deduplicating keeps the newest copy of each.',
    evidenceCount: 42, confidence: 0.86,
    proposedStrategy: { id: 'a7a7a7a7-0000-4000-8000-0000000000b1', kind: 'deduplicate', ageHours: 24, keepCount: 1, fromBotsOnly: false },
    proposedSchedule: { daily: { hour: 3 } }, createdAt: minutesAgo(600),
    projection: sweepReport('a7a7a7a7-0000-4000-8000-0000000000c1', 'a7a7a7a7-0000-4000-8000-000000000001', 'Suggested: deduplicate', 600, { dryRun: true })
  }],
  isScanningSuggestions: false, lastSuggestionScanAt: minutesAgo(600),
  scanProgressDone: 0, scanProgressTotal: 0, servers: serverOptions, textChannelsByServer: textByServer
};

const gametracker = {
  enabled: true, dailyCheckEnabled: true, sessionTrackingEnabled: true, statusText: 'Tracking 3 players', statusTone: 'success',
  configurationIssue: null, checkInProgress: false, scheduleDescription: 'Daily at 9:00 am', lastCheckAt: minutesAgo(300), nextCheckAt: minutesAgo(-1140),
  enabledPlayerCount: 3, totalPlayerCount: 3,
  players: [
    // Real finals.id numbers for jonwatso#5331 (captured 2026-10-01).
    { id: 'p0', game: 'theFinals', gameDisplayName: 'THE FINALS', provider: 'finalsID', providerDisplayName: 'Finals ID', playerID: 'jonwatso#5331', displayName: 'jonwatso', destinationChannelID: 't100', destinationChannelName: 'general', isEnabled: true, supportsRankedScore: true, season: 'S11', rankName: 'Gold', score: 28160, baselineRecordedAt: '2026-09-29T09:03:10Z', discordUserID: '412378964087275541', triggerMetrics: ['rankedScore', 'rankTier'], contextMetrics: ['killDeathRatio', 'wins'] },
    { id: 'p1', game: 'theFinals', gameDisplayName: 'THE FINALS', provider: 'finalsID', providerDisplayName: 'Finals ID', playerID: 'sam#1234', displayName: 'sam', destinationChannelID: 't100', destinationChannelName: 'general', isEnabled: true, supportsRankedScore: true, season: 'S6', rankName: 'Gold 2', score: 18420, baselineRecordedAt: minutesAgo(2000), discordUserID: '280129381292318720', triggerMetrics: ['rankedScore'], contextMetrics: ['killDeathRatio', 'wins'] },
    { id: 'p2', game: 'theFinals', gameDisplayName: 'THE FINALS', provider: 'finalsID', providerDisplayName: 'Finals ID', playerID: 'alex#9876', displayName: 'alex', destinationChannelID: 't100', destinationChannelName: 'general', isEnabled: true, supportsRankedScore: true, season: 'S6', rankName: 'Silver 1', score: 11203, baselineRecordedAt: minutesAgo(2000), discordUserID: '', triggerMetrics: ['rankedScore', 'rankTier'], contextMetrics: [] }
  ],
  history: [
    { id: 'h1', timestamp: minutesAgo(300), kind: 'announcement', title: 'Rank update posted', detail: 'sam climbed to Gold 2 (+420)' },
    { id: 'h2', timestamp: '2026-09-30T10:30:29Z', kind: 'sessionEnded', title: 'Play session posted', detail: 'jonwatso · 2h 6m · 6 matches, 1 win · 67 kills' },
    { id: 'h3', timestamp: '2026-09-29T09:03:10Z', kind: 'announcement', title: 'Rank update posted', detail: 'jonwatso dropped to 28,160 SR (−674)' }
  ],
  isPollingRuntime: false,
  checkHour: 9, timeZoneIdentifier: 'Pacific/Auckland', linkedPlayerCount: 2,
  sessionMinimumMinutes: 5, sessionGraceMinutes: 3, isFailoverManagedNode: false,
  // Mirrors AdminWebGameTrackerCatalog built from GameID / GameProviderCatalog.
  catalog: {
    games: [{ id: 'theFinals', displayName: 'THE FINALS', symbolName: 'scope' }],
    providers: [{
      id: 'finalsID', displayName: 'Finals ID', supportedGames: ['theFinals'], isConfigured: true,
      metrics: [
        ['rankedScore', 'Ranked Score', true], ['rankTier', 'Rank', true], ['kills', 'Kills', false], ['deaths', 'Deaths', false],
        ['assists', 'Assists', false], ['killDeathRatio', 'K/D', true], ['damage', 'Damage', false],
        ['matchesPlayed', 'Matches', false], ['wins', 'Wins', false], ['winRate', 'Win Rate', true]
      ].map(([id, displayName, canTrigger]) => ({ id, displayName, canTrigger }))
    }]
  },
  channels: textChannels.map(c => ({ id: c.id, name: `Swift Lounge · #${c.name}` })),
  members: [
    { id: '412378964087275541', name: 'jonwatso', username: null },
    { id: '280129381292318720', name: 'Sam', username: 'samthegreat' },
    { id: '280129381292318721', name: 'Alex', username: null },
    { id: '280129381292318722', name: 'Jordan', username: 'jordan_ttv' }
  ]
};

const mediaItem = (i, game) => ({
  id: `m${i}`, nodeName: 'Preview Mac', sourceName: 'Clips', gameName: game, fileName: `${game.replace(/\W/g, '')}-${i}.mp4`,
  relativePath: `Clips/${game}/${i}.mp4`, fileExtension: 'mp4', sizeBytes: 48_000_000 + i * 1_000_000,
  modifiedAt: minutesAgo([20, 140, 1500, 1620, 4400, 9000][i - 1] ?? i * 90), thumbnailURL: '', streamURL: ''
});
const media = {
  generatedAt: new Date().toISOString(),
  sources: [{ id: 'clips', nodeName: 'Preview Mac', sourceName: 'Clips', itemCount: 6 }],
  items: [
    ...[1, 2, 3, 4, 5, 6].map(i => mediaItem(i, i % 2 ? 'THE FINALS' : 'Minecraft')),
    ...[[7, 'Apex Legends', 2900], [8, 'Apex Legends', 3100], [9, 'Helldivers 2', 5800], [10, 'Counter-Strike 2', 12000], [11, 'Helldivers 2', 7300]]
      .map(([i, game, mins]) => ({ ...mediaItem(i, game), modifiedAt: minutesAgo(mins) }))
  ],
  games: ['Apex Legends', 'Counter-Strike 2', 'Helldivers 2', 'Minecraft', 'THE FINALS'], selectedSourceID: null, selectedDateRange: 'all', selectedGame: null,
  page: 1, pageSize: 24, totalItems: 11, totalPages: 1
};
const mediaExports = {
  jobs: [
    { id: 'j1', kind: 'clip', status: 'finished', createdAt: minutesAgo(30), finishedAt: minutesAgo(29), outputFileName: 'Final_round_clutch.mp4', nodeName: 'Preview Mac' },
    { id: 'j2', kind: 'multiview', status: 'failed', createdAt: minutesAgo(200), message: 'Second recording is shorter than the selected window.', nodeName: 'Preview Mac' }
  ]
};

module.exports = {
  announcer, me, overview, status, analytics, rewind, authOptions,
  config, commands, automations, automationRules, welcomeFlow, patchy, aibots, wikibridge, sweep, gametracker, media, mediaExports
};
