import { Activity, Bell, Power, Search } from 'lucide-react';
import { TabId, TAB_LABELS } from '../tabs';

type Props = { active: TabId };

export function Header({ active }: Props) {
  return (
    <header className="h-20 border-b border-white/5 flex items-center justify-between px-8 bg-slate-950/20 backdrop-blur-md z-10">
      <div
        className="flex items-center gap-4 animate-in"
        style={{ animationDelay: '0.1s' }}
      >
        <h2 className="text-xl font-bold text-white">{TAB_LABELS[active]}</h2>
        <div className="h-4 w-[1px] bg-white/10" />
        <div className="flex items-center gap-2 text-slate-500 text-sm">
          <Activity size={14} className="text-emerald-400 animate-pulse" />
          System Nominal
        </div>
      </div>

      <div
        className="flex items-center gap-4 animate-in"
        style={{ animationDelay: '0.2s' }}
      >
        <div className="relative group">
          <Search
            size={18}
            className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-500 group-focus-within:text-blue-400 transition-colors"
          />
          <input
            type="text"
            placeholder="Global search..."
            className="bg-white/5 border border-white/5 rounded-xl pl-10 pr-4 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500/50 w-64 transition-all"
          />
        </div>
        <button className="p-2.5 rounded-xl bg-white/5 hover:bg-white/10 transition-colors relative">
          <Bell size={20} />
          <div className="absolute top-2.5 right-2.5 w-2 h-2 bg-blue-500 rounded-full border-2 border-slate-900" />
        </button>
        <button className="flex items-center gap-2 px-5 py-2.5 bg-blue-600 hover:bg-blue-500 text-white rounded-xl font-semibold transition-all shadow-lg shadow-blue-600/20 active:scale-95">
          <Power size={18} />
          Restart Bot
        </button>
      </div>
    </header>
  );
}
