import { useEffect, useState } from 'react';

type Props = {
  value: string | number;
  delay?: string;
  duration?: number;
};

export function CountUp({ value, delay = '0s', duration = 2000 }: Props) {
  const [count, setCount] = useState(0);

  const stringValue = String(value);
  const isNumericValue = /[0-9]/.test(stringValue);
  const numericPart = isNumericValue
    ? parseFloat(stringValue.replace(/,/g, ''))
    : 0;
  const suffix = isNumericValue ? stringValue.replace(/[0-9.,]/g, '') : '';
  const decimalMatches = isNumericValue ? stringValue.match(/\.([0-9]+)/) : null;
  const decimalPlaces = decimalMatches ? decimalMatches[1].length : 0;

  useEffect(() => {
    if (!isNumericValue) return;
    const delayMs = parseFloat(delay) * 1000;
    const startTime = Date.now() + delayMs;
    let frame: number;
    const update = () => {
      const now = Date.now();
      if (now < startTime) {
        frame = requestAnimationFrame(update);
        return;
      }
      const progress = Math.min((now - startTime) / duration, 1);
      const eased = progress === 1 ? 1 : 1 - Math.pow(2, -10 * progress);
      setCount(eased * numericPart);
      if (progress < 1) frame = requestAnimationFrame(update);
    };
    frame = requestAnimationFrame(update);
    return () => cancelAnimationFrame(frame);
  }, [numericPart, delay, duration, isNumericValue]);

  if (!isNumericValue) return <>{value}</>;

  return (
    <span>
      {count.toLocaleString(undefined, {
        minimumFractionDigits: decimalPlaces,
        maximumFractionDigits: decimalPlaces,
      })}
      {suffix}
    </span>
  );
}
