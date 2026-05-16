export type TabId =
  | 'overview'
  | 'commands'
  | 'actions'
  | 'patchy'
  | 'wikibridge'
  | 'aibots'
  | 'voice'
  | 'swiftmesh'
  | 'diagnostics'
  | 'logs'
  | 'settings';

export const TAB_LABELS: Record<TabId, string> = {
  overview: 'Overview',
  commands: 'Commands',
  actions: 'Actions',
  patchy: 'Patchy',
  wikibridge: 'WikiBridge',
  aibots: 'AI Bots',
  voice: 'Voice',
  swiftmesh: 'SwiftMesh',
  diagnostics: 'Diagnostics',
  logs: 'Logs',
  settings: 'Settings',
};
