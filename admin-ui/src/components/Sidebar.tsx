import {
  Activity,
  Bot,
  Cpu,
  History,
  LayoutDashboard,
  Library,
  LucideIcon,
  Mic,
  Network,
  Settings,
  ShieldAlert,
  Terminal,
  Zap,
} from 'lucide-react';
import { TabId } from '../tabs';

type Props = {
  active: TabId;
  onSelect: (id: TabId) => void;
};

type Item = { id: TabId; label: string; icon: LucideIcon };

const groups: { heading: string; items: Item[] }[] = [
  {
    heading: 'Dashboard',
    items: [{ id: 'overview', label: 'Overview', icon: LayoutDashboard }],
  },
  {
    heading: 'Automation',
    items: [
      { id: 'commands', label: 'Commands', icon: Terminal },
      { id: 'actions', label: 'Actions', icon: Zap },
      { id: 'patchy', label: 'Patchy', icon: ShieldAlert },
      { id: 'wikibridge', label: 'WikiBridge', icon: Library },
    ],
  },
  {
    heading: 'System',
    items: [
      { id: 'aibots', label: 'AI Bots', icon: Cpu },
      { id: 'voice', label: 'Voice', icon: Mic },
      { id: 'swiftmesh', label: 'SwiftMesh', icon: Network },
      { id: 'diagnostics', label: 'Diagnostics', icon: Activity },
      { id: 'logs', label: 'Logs', icon: History },
      { id: 'settings', label: 'Settings', icon: Settings },
    ],
  },
];

export function Sidebar({ active, onSelect }: Props) {
  return (
    <aside className="w-64 border-r border-white/5 bg-slate-950/50 backdrop-blur-2xl flex flex-col p-6">
      <div
        className="flex items-center gap-3 mb-10 px-2 animate-in"
        style={{ animationDelay: '0.1s' }}
      >
        <div className="w-10 h-10 bg-gradient-to-br from-blue-500 to-indigo-600 rounded-xl flex items-center justify-center shadow-lg shadow-blue-500/20">
          <Bot className="text-white" size={24} />
        </div>
        <div>
          <h1 className="text-lg font-bold text-white leading-tight">
            SwiftBot
          </h1>
          <span className="text-[10px] text-slate-500 uppercase font-bold tracking-widest">
            Web Admin v2.0
          </span>
        </div>
      </div>

      <div
        className="flex-1 space-y-8 overflow-y-auto custom-scrollbar pr-2 animate-in"
        style={{ animationDelay: '0.2s' }}
      >
        {groups.map((g) => (
          <div key={g.heading}>
            <p className="text-[10px] font-bold text-slate-500 uppercase tracking-widest mb-4 px-4">
              {g.heading}
            </p>
            <nav className="space-y-1">
              {g.items.map((item) => {
                const isActive = active === item.id;
                const Icon = item.icon;
                return (
                  <button
                    key={item.id}
                    onClick={() => onSelect(item.id)}
                    className={`w-full flex items-center gap-3 px-4 py-3 rounded-xl transition-all duration-200 group ${
                      isActive
                        ? 'bg-blue-500/20 text-blue-400 border border-blue-500/30'
                        : 'text-slate-400 hover:bg-white/5 hover:text-slate-200'
                    }`}
                  >
                    <Icon
                      size={18}
                      className={
                        isActive ? 'text-blue-400' : 'group-hover:text-slate-200'
                      }
                    />
                    <span className="text-sm font-medium">{item.label}</span>
                    {isActive && (
                      <div className="ml-auto w-1 h-4 bg-blue-400 rounded-full" />
                    )}
                  </button>
                );
              })}
            </nav>
          </div>
        ))}
      </div>

      <div
        className="mt-auto pt-6 border-t border-white/5 animate-in"
        style={{ animationDelay: '0.3s' }}
      >
        <div className="flex items-center gap-3 p-2 bg-white/5 rounded-2xl hover:bg-white/10 transition-colors cursor-pointer group">
          <div className="relative">
            <div className="w-10 h-10 rounded-xl overflow-hidden bg-slate-700">
              <div className="w-full h-full bg-gradient-to-tr from-amber-500 to-orange-400 flex items-center justify-center text-white font-bold">
                JW
              </div>
            </div>
            <div className="absolute -bottom-1 -right-1 w-4 h-4 bg-emerald-500 border-2 border-slate-950 rounded-full" />
          </div>
          <div className="flex-1 min-w-0">
            <p className="text-sm font-semibold text-white truncate">
              jonwatso
            </p>
            <p className="text-[10px] text-slate-500 truncate">@jonwatso</p>
          </div>
          <Settings
            size={16}
            className="text-slate-500 group-hover:text-white transition-colors"
          />
        </div>
      </div>
    </aside>
  );
}
