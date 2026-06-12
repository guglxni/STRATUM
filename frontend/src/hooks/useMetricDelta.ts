/**
 * Metric delta tracker (spec §6.6): remembers the previous polled value and, when it changes beyond
 * a tolerance, returns the signed delta for a hold window so the dashboard can flash a card and show
 * a +Δ sublabel. Fixes the §2.1 "looks unchanged" problem on rounded cards after a deposit.
 */

import { useEffect, useRef, useState } from "react";

export function useMetricDelta(value: number | undefined, tolerance = 0, holdMs = 30_000): number | null {
  const prev = useRef<number | undefined>(undefined);
  const [delta, setDelta] = useState<number | null>(null);

  useEffect(() => {
    if (value === undefined) return;
    if (prev.current !== undefined && Math.abs(value - prev.current) > tolerance) {
      setDelta(value - prev.current);
      prev.current = value;
      const t = setTimeout(() => setDelta(null), holdMs);
      return () => clearTimeout(t);
    }
    prev.current = value;
  }, [value, tolerance, holdMs]);

  return delta;
}
