import { useState } from 'react';
import {
  Activity,
  Bot,
  ChevronRight,
  Library,
  Mic,
  MessageSquare,
  Network,
  Power,
  ShieldAlert,
  Terminal,
  User,
} from 'lucide-react';
import {
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
} from 'recharts';
import { GlassCard } from '../components/GlassCard';
import { StatCard } from '../components/StatCard';

const COMMAND_HISTORY_DATA = [
  { time: '12:00', count: 12 },
  { time: '13:00', count: 18 },
  { time: '14:00', count: 15 },
  { time: '15:00', count: 25 },
  { time: '16:00', count: 22 },
  { time: '17:00', count: 30 },
  { time: '18:00', count: 28 },
];

const RECENT_VOICE = [
  {
    id: 1,
    user: 'Max',
    action: 'LEAVE',
    channel: 'Friends of the AO',
    duration: '133m 41s',
    time: '11:00:21 PM',
  },
  {
    id: 2,
    user: 'Gabe',
    action: 'JOIN',
    channel: 'General Chat',
    duration: '0m',
    time: '10:58:26 PM',
  },
  {
    id: 3,
    user: 'Sarah',
    action: 'LEAVE',
    channel: 'Music Lounge',
    duration: '45m 12s',
    time: '10:15:05 PM',
  },
];

const RECENT_COMMANDS = [
  {
    id: 1,
    user: 'jonwatso',
    server: 'DA BOIS',
    command: '/debug',
    time: '8:48:15 PM',
  },
  {
    id: 2,
    user: 'alex_dev',
    server: 'Testing Lab',
    command: '/sync',
    time: '8:42:10 PM',
  },
  {
    id: 3,
    user: 'bot_admin',
    server: 'Official Server',
    command: '/deploy',
    time: '8:30:00 PM',
  },
];

const stats = [
  {
    icon: Activity,
    title: 'Bot Status',
    value: 'Running',
    subtext: '02h 16m 57s',
    statusColor: 'text-emerald-400',
  },
  {
    icon: Network,
    title: 'Servers',
    value: '142',
    subtext: '3 Primary',
    statusColor: 'text-blue-400',
    trend: '+12%',
  },
  {
    icon: User,
    title: 'Users In Voice',
    value: '1,204',
    subtext: 'Peak: 2,4k today',
    statusColor: 'text-amber-400',
  },
  {
    icon: MessageSquare,
    title: 'Commands Run',
    value: '1.2k',
    subtext: 'Last 24 hours',
    statusColor: 'text-purple-400',
    trend: '+4.2%',
  },
  {
    icon: Library,
    title: 'WikiBridge',
    value: 'Enabled',
    subtext: '1 sources active',
    statusColor: 'text-emerald-400',
  },
  {
    icon: ShieldAlert,
    title: 'Monitoring',
    value: 'Online',
    subtext: '2/2 targets live',
    statusColor: 'text-blue-400',
  },
];

export function Overview() {
  const [isAiEnabled, setIsAiEnabled] = useState(true);

  return (
    <div className="p-8">
      <div className="grid grid-cols-1 md:grid-cols-3 lg:grid-cols-6 gap-6 mb-8">
        {stats.map((stat, i) => (
          <StatCard key={i} {...stat} delay={`${0.1 + i * 0.05}s`} />
        ))}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8 mb-8">
        <GlassCard className="lg:col-span-2 p-6 flex flex-col" delay="0.4s">
          <div className="flex items-center justify-between mb-6">
            <div>
              <h3 className="text-lg font-bold text-white">Usage Trends</h3>
              <p className="text-sm text-slate-500">
                Command executions per hour
              </p>
            </div>
            <select className="bg-white/5 border border-white/10 rounded-lg text-xs px-3 py-1.5 focus:outline-none">
              <option>Last 24 Hours</option>
              <option>Last 7 Days</option>
            </select>
          </div>
          <div className="flex-1 h-[200px] w-full">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={COMMAND_HISTORY_DATA}>
                <Tooltip
                  contentStyle={{
                    backgroundColor: '#1e293b',
                    borderColor: '#334155',
                    borderRadius: '12px',
                  }}
                  itemStyle={{ color: '#fff' }}
                />
                <Line
                  type="monotone"
                  dataKey="count"
                  stroke="#3b82f6"
                  strokeWidth={4}
                  dot={{ fill: '#3b82f6', strokeWidth: 2, r: 4 }}
                  activeDot={{ r: 8, strokeWidth: 0 }}
                />
              </LineChart>
            </ResponsiveContainer>
          </div>
        </GlassCard>

        <GlassCard
          className="p-6 bg-gradient-to-br from-purple-600/10 to-transparent border-purple-500/20"
          delay="0.5s"
        >
          <div className="flex items-center justify-between mb-6">
            <div className="p-3 bg-purple-500/20 rounded-2xl">
              <Bot className="text-purple-400" size={24} />
            </div>
            <span className="text-[10px] font-bold text-purple-400 bg-purple-400/10 px-2 py-1 rounded-full uppercase tracking-tighter">
              AI System
            </span>
          </div>
          <h3 className="text-2xl font-bold text-white mb-2">
            Apple Intelligence
          </h3>
          <p className="text-slate-400 text-sm mb-6 leading-relaxed">
            Natural language processing is currently active for all incoming
            direct messages.
          </p>
          <div className="space-y-4">
            <div className="flex items-center justify-between p-4 bg-white/5 rounded-2xl border border-white/5">
              <span className="text-sm font-medium text-slate-300">
                System Status
              </span>
              <div className="flex items-center gap-2">
                <div
                  className={`w-2 h-2 rounded-full ${
                    isAiEnabled
                      ? 'bg-emerald-500 animate-pulse'
                      : 'bg-slate-500'
                  }`}
                />
                <span
                  className={`text-xs font-bold uppercase tracking-wider ${
                    isAiEnabled ? 'text-emerald-400' : 'text-slate-500'
                  }`}
                >
                  {isAiEnabled ? 'Online' : 'Offline'}
                </span>
              </div>
            </div>
            <button
              onClick={() => setIsAiEnabled(!isAiEnabled)}
              className={`w-full py-3 rounded-xl text-sm font-semibold transition-all flex items-center justify-center gap-2 ${
                isAiEnabled
                  ? 'bg-rose-500/10 text-rose-400 border border-rose-500/20 hover:bg-rose-500/20'
                  : 'bg-purple-600 text-white shadow-lg shadow-purple-600/20 hover:bg-purple-500'
              }`}
            >
              <Power size={16} />
              {isAiEnabled ? 'Disable AI Response' : 'Enable AI Response'}
            </button>
          </div>
        </GlassCard>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <GlassCard delay="0.6s">
          <div className="p-6 border-b border-white/5 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <div className="p-2 bg-blue-500/20 rounded-lg">
                <Mic size={18} className="text-blue-400" />
              </div>
              <h3 className="font-bold text-white">Recent Voice Activity</h3>
            </div>
            <button className="text-xs text-blue-400 hover:underline">
              View All
            </button>
          </div>
          <div className="p-2">
            {RECENT_VOICE.map((item) => (
              <div
                key={item.id}
                className="flex items-center gap-4 p-4 hover:bg-white/5 rounded-xl transition-colors group"
              >
                <div
                  className={`w-2 h-2 rounded-full ${
                    item.action === 'LEAVE'
                      ? 'bg-rose-500'
                      : 'bg-emerald-500 shadow-[0_0_8px_rgba(16,185,129,0.5)]'
                  }`}
                />
                <div className="flex-1">
                  <p className="text-sm font-medium text-white">
                    <span className="text-blue-400 font-bold">{item.user}</span>{' '}
                    {item.action.toLowerCase()}d{' '}
                    <span className="text-slate-400">"{item.channel}"</span>
                  </p>
                  <p className="text-[10px] text-slate-500 mt-0.5">
                    {item.time} • Duration: {item.duration}
                  </p>
                </div>
                <ChevronRight
                  size={14}
                  className="text-slate-600 group-hover:text-slate-400 transition-colors"
                />
              </div>
            ))}
          </div>
        </GlassCard>

        <GlassCard delay="0.7s">
          <div className="p-6 border-b border-white/5 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <div className="p-2 bg-purple-500/20 rounded-lg">
                <Terminal size={18} className="text-purple-400" />
              </div>
              <h3 className="font-bold text-white">Recent Commands</h3>
            </div>
            <button className="text-xs text-blue-400 hover:underline">
              View All
            </button>
          </div>
          <div className="p-2">
            {RECENT_COMMANDS.map((item) => (
              <div
                key={item.id}
                className="flex items-center gap-4 p-4 hover:bg-white/5 rounded-xl transition-colors group"
              >
                <div className="w-10 h-10 rounded-lg bg-slate-800 flex items-center justify-center font-bold text-slate-500 group-hover:text-white transition-colors">
                  {item.user[0].toUpperCase()}
                </div>
                <div className="flex-1">
                  <div className="flex items-center gap-2">
                    <span className="text-sm font-bold text-white">
                      {item.user}
                    </span>
                    <span className="text-[10px] px-1.5 py-0.5 bg-white/5 rounded text-slate-400">
                      @{item.server}
                    </span>
                  </div>
                  <code className="text-xs text-purple-400 bg-purple-400/5 px-1.5 py-0.5 rounded mt-1 inline-block">
                    {item.command}
                  </code>
                </div>
                <span className="text-[10px] text-slate-600">{item.time}</span>
              </div>
            ))}
          </div>
        </GlassCard>
      </div>
    </div>
  );
}
