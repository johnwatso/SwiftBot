import { Circle, LucideIcon } from 'lucide-react';
import { GlassCard } from './GlassCard';
import { CountUp } from './CountUp';

type Props = {
  icon: LucideIcon;
  title: string;
  value: string;
  subtext: string;
  statusColor?: string;
  trend?: string;
  delay?: string;
};

export function StatCard({
  icon: Icon,
  title,
  value,
  subtext,
  statusColor = 'text-emerald-400',
  trend,
  delay,
}: Props) {
  return (
    <GlassCard className="p-5 group" delay={delay}>
      <div className="flex justify-between items-start mb-4">
        <div
          className={`p-2 rounded-lg bg-white/5 group-hover:scale-110 transition-transform ${statusColor}`}
        >
          <Icon size={20} />
        </div>
        {trend && (
          <span
            className={`text-xs px-2 py-1 rounded-full bg-white/5 ${
              trend.startsWith('+') ? 'text-emerald-400' : 'text-rose-400'
            }`}
          >
            {trend}
          </span>
        )}
      </div>
      <div>
        <h3 className="text-slate-400 text-xs font-medium uppercase tracking-wider mb-1">
          {title}
        </h3>
        <div className="text-2xl font-bold text-white tracking-tight">
          <CountUp value={value} delay={delay} />
        </div>
        <p className="text-slate-500 text-xs mt-1 flex items-center gap-1">
          <Circle size={8} className={`fill-current ${statusColor}`} />
          {subtext}
        </p>
      </div>
    </GlassCard>
  );
}
