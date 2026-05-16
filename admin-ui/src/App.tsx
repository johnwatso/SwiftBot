import { useState } from 'react';
import { Sidebar } from './components/Sidebar';
import { Header } from './components/Header';
import { Overview } from './pages/Overview';
import { Placeholder } from './pages/Placeholder';
import { TabId, TAB_LABELS } from './tabs';

export default function App() {
  const [active, setActive] = useState<TabId>('overview');

  return (
    <div className="min-h-screen bg-[#0a0c14] text-slate-200 font-sans selection:bg-blue-500/30">
      <div className="fixed inset-0 pointer-events-none opacity-20 overflow-hidden">
        <div className="absolute top-[-10%] left-[-10%] w-[40%] h-[40%] bg-blue-600/20 rounded-full blur-[120px]" />
        <div className="absolute bottom-[-10%] right-[-10%] w-[40%] h-[40%] bg-purple-600/20 rounded-full blur-[120px]" />
      </div>

      <div className="relative flex h-screen overflow-hidden">
        <Sidebar active={active} onSelect={setActive} />
        <main className="flex-1 flex flex-col overflow-hidden bg-white/[0.01]">
          <Header active={active} />
          <div className="flex-1 overflow-y-auto custom-scrollbar">
            {active === 'overview' ? (
              <Overview />
            ) : (
              <Placeholder title={TAB_LABELS[active]} />
            )}
          </div>
        </main>
      </div>
    </div>
  );
}
