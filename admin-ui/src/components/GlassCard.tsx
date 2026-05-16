import { ReactNode } from 'react';
import { cn } from '../lib/cn';

type Props = {
  children: ReactNode;
  className?: string;
  delay?: string;
};

export function GlassCard({ children, className = '', delay = '0s' }: Props) {
  return (
    <div
      className={cn(
        'bg-slate-900/40 backdrop-blur-xl border border-white/10 rounded-2xl overflow-hidden hover:border-white/20 transition-all duration-300 animate-in',
        className,
      )}
      style={{ animationDelay: delay }}
    >
      {children}
    </div>
  );
}
