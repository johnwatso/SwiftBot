import { Construction } from 'lucide-react';
import { GlassCard } from '../components/GlassCard';

type Props = { title: string };

export function Placeholder({ title }: Props) {
  return (
    <div className="p-8">
      <GlassCard className="p-12 flex flex-col items-center justify-center text-center" delay="0.1s">
        <div className="p-4 bg-blue-500/20 rounded-2xl mb-4">
          <Construction className="text-blue-400" size={28} />
        </div>
        <h3 className="text-xl font-bold text-white mb-2">{title}</h3>
        <p className="text-slate-400 text-sm max-w-md">
          This view hasn't been ported into the new admin yet. The old admin UI
          will be replaced section-by-section.
        </p>
      </GlassCard>
    </div>
  );
}
