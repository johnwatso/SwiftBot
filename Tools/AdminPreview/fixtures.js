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
  metrics: [
    { id: 'servers', title: 'Servers', value: '2', detail: 'Connected', trend: '', tone: 'ok' },
    { id: 'voice', title: 'Announcers', value: '2', detail: '1 active', trend: '', tone: 'ok' }
  ],
  cluster: { connectedNodes: 1, leader: 'this node', mode: 'Standalone' },
  botInfo: { uptime: '3h 12m', errors: 0, state: 'Connected' },
  recentVoice: [
    { description: 'Joined General Voice', timeText: '2m ago' },
    { description: 'Left Stream Room', timeText: '18m ago' }
  ],
  recentCommands: [{ title: '/announce join', ok: true, timeText: '2m ago' }],
  activeVoice: []
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

const authOptions = { discordEnabled: false, localEnabled: true, botName: 'SwiftBot (Preview)', botAvatarURL: '' };

module.exports = { announcer, me, overview, status, analytics, authOptions };
