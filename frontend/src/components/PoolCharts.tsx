/**
 * PoolCharts - visual analytics derived purely from the live pool snapshot.
 *
 * No subgraph and no historical indexer needed: the donut, gauge, waterfall, and fee-band are all
 * computed from the current `poolState`/lens read. The sparkline additionally accumulates each 10s
 * poll into a session-local time series, so the dashboard shows live movement without any backend.
 *
 * Everything is hand-rolled SVG + CSS transitions (no chart dependency) so it stays light and the
 * animation is GPU-cheap.
 */

import { useEffect, useRef, useState } from "react";
import { formatUnits } from "viem";

interface PoolChartsProps {
  seniorTVL: bigint;
  juniorTVL: bigint;
  juniorReserve: bigint;
  reserveTokens: bigint;
  coverageRatioBps: number;
  minCoverageRatioBps: number;
  nextSwapFeeBps: number;
  minFeeBps: number;
  maxFeeBps: number;
  baseFeeBps: number;
  epochSeniorFunded: bigint;
  epochSeniorObligation: bigint;
  epochAccumulatedFees: bigint;
}

const toNum = (v: bigint) => parseFloat(formatUnits(v, 18));

function fmt(n: number): string {
  if (n === 0) return "0";
  if (n < 0.001) return "<0.001";
  if (n < 1) return n.toFixed(4);
  if (n < 1_000) return n.toFixed(2);
  if (n < 1_000_000) return (n / 1_000).toFixed(2) + "K";
  return (n / 1_000_000).toFixed(2) + "M";
}

/** Animated number that eases toward its target whenever the target changes. */
function useCountUp(target: number, durationMs = 600): number {
  const [val, setVal] = useState(target);
  const fromRef = useRef(target);
  const startRef = useRef(0);
  const rafRef = useRef(0);

  useEffect(() => {
    const from = fromRef.current;
    const delta = target - from;
    if (delta === 0) return;
    let mounted = true;
    const step = (t: number) => {
      if (!mounted) return;
      if (!startRef.current) startRef.current = t;
      const p = Math.min(1, (t - startRef.current) / durationMs);
      const eased = 1 - Math.pow(1 - p, 3); // easeOutCubic
      setVal(from + delta * eased);
      if (p < 1) {
        rafRef.current = requestAnimationFrame(step);
      } else {
        fromRef.current = target;
        startRef.current = 0;
      }
    };
    rafRef.current = requestAnimationFrame(step);
    return () => {
      mounted = false;
      cancelAnimationFrame(rafRef.current);
      startRef.current = 0;
      fromRef.current = target;
    };
  }, [target, durationMs]);

  return val;
}

const MAX_POINTS = 40;

/** Accumulates a value into a capped session series each time `sample` changes. */
function useSessionSeries(sample: number): number[] {
  const [series, setSeries] = useState<number[]>([sample]);
  const last = useRef(sample);
  useEffect(() => {
    if (sample === last.current && series.length > 1) return;
    last.current = sample;
    setSeries((s) => {
      const next = [...s, sample];
      return next.length > MAX_POINTS ? next.slice(next.length - MAX_POINTS) : next;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sample]);
  return series;
}

function stressColor(ratioBps: number, floorBps: number): string {
  if (ratioBps >= floorBps * 2) return "var(--ok, #1f9d55)";
  if (ratioBps >= floorBps * 1.5) return "#c98a00";
  if (ratioBps >= floorBps) return "#d2691e";
  return "#c0392b";
}

export default function PoolCharts(p: PoolChartsProps) {
  const senior = toNum(p.seniorTVL);
  const junior = toNum(p.juniorTVL);
  const total = senior + junior;
  const seniorPct = total > 0 ? (senior / total) * 100 : 0;
  const juniorPct = total > 0 ? (junior / total) * 100 : 0;

  // Coverage gauge: fill is ratio / (2*floor), clamped to 1 (2x floor reads as "full health").
  const floor = p.minCoverageRatioBps || 1;
  const gaugeFrac = Math.max(0, Math.min(1, p.coverageRatioBps / (floor * 2)));
  const covColor = stressColor(p.coverageRatioBps, floor);

  // Waterfall: fees in -> senior obligation funded -> junior surplus.
  const feesIn = toNum(p.epochAccumulatedFees);
  const obligation = toNum(p.epochSeniorObligation);
  const funded = toNum(p.epochSeniorFunded);
  const surplus = Math.max(0, feesIn - obligation);
  const wfMax = Math.max(feesIn, obligation, 1e-18);

  // Fee band marker position.
  const feeLo = p.minFeeBps;
  const feeHi = Math.max(p.maxFeeBps, p.minFeeBps + 1);
  const pos = (bps: number) => `${Math.max(0, Math.min(100, ((bps - feeLo) / (feeHi - feeLo)) * 100))}%`;

  // Live series: coverage ratio (%) over the session.
  const covPct = p.coverageRatioBps / 100;
  const covSeries = useSessionSeries(Number(covPct.toFixed(2)));

  // Animated headline numbers.
  const covAnim = useCountUp(p.coverageRatioBps / 100);
  const seniorAnim = useCountUp(seniorPct);
  const juniorAnim = useCountUp(juniorPct);

  // Donut geometry.
  const R = 52;
  const C = 2 * Math.PI * R;
  const seniorLen = (seniorPct / 100) * C;

  return (
    <div className="charts-section">
      <div className="charts-head">
        <h3>Live analytics</h3>
        <span className="charts-sub">Derived from the current on-chain snapshot &middot; updates every 10s</span>
      </div>

      <div className="charts-grid">
        {/* TVL donut */}
        <div className="chart-card reveal-up">
          <div className="chart-title">Tranche split</div>
          <div className="donut-wrap">
            <svg viewBox="0 0 140 140" className="donut">
              {/* Base ring = junior (the remainder); senior arc overlays it from 12 o'clock. */}
              <circle cx="70" cy="70" r={R} className="donut-track" />
              {total > 0 && <circle cx="70" cy="70" r={R} className="donut-junior" />}
              {total > 0 && (
                <circle
                  cx="70"
                  cy="70"
                  r={R}
                  className="donut-senior"
                  strokeDasharray={`${seniorLen} ${C - seniorLen}`}
                  transform="rotate(-90 70 70)"
                />
              )}
              <text x="70" y="66" className="donut-center-num">
                {fmt(total)}
              </text>
              <text x="70" y="84" className="donut-center-label">
                total TVL
              </text>
            </svg>
            <div className="donut-legend">
              <div className="leg">
                <span className="leg-dot leg-senior" /> Senior <b>{seniorAnim.toFixed(1)}%</b>
                <span className="leg-amt">{fmt(senior)}</span>
              </div>
              <div className="leg">
                <span className="leg-dot leg-junior" /> Junior <b>{juniorAnim.toFixed(1)}%</b>
                <span className="leg-amt">{fmt(junior)}</span>
              </div>
            </div>
          </div>
        </div>

        {/* Coverage gauge */}
        <div className="chart-card reveal-up" style={{ animationDelay: "60ms" }}>
          <div className="chart-title">Coverage health</div>
          <div className="gauge-wrap">
            <svg viewBox="0 0 160 92" className="gauge">
              <path d="M12 86 A 68 68 0 0 1 148 86" className="gauge-track" />
              <path
                d="M12 86 A 68 68 0 0 1 148 86"
                className="gauge-fill"
                style={{ stroke: covColor, strokeDasharray: 213.6, strokeDashoffset: 213.6 * (1 - gaugeFrac) }}
              />
              {/* floor marker at floor/(2*floor) = 50% of the arc */}
              <line x1="80" y1="20" x2="80" y2="6" className="gauge-floor" />
            </svg>
            <div className="gauge-readout">
              <div className="gauge-num" style={{ color: covColor }}>
                {covAnim.toFixed(1)}%
              </div>
              <div className="gauge-label">
                coverage &middot; floor {(floor / 100).toFixed(0)}% <span className="gauge-floor-tag">2x = full</span>
              </div>
            </div>
          </div>
        </div>

        {/* Waterfall allocation */}
        <div className="chart-card reveal-up" style={{ animationDelay: "120ms" }}>
          <div className="chart-title">Epoch waterfall</div>
          <div className="wf-bars">
            <WfBar label="Swap fees in" value={feesIn} max={wfMax} cls="wf-fees" fmt={fmt} />
            <WfBar label={`Senior funded (${fmt(funded)}/${fmt(obligation)})`} value={funded} max={wfMax} cls="wf-senior" fmt={fmt} />
            <WfBar label="Junior surplus" value={surplus} max={wfMax} cls="wf-junior" fmt={fmt} />
          </div>
          <div className="wf-foot">Senior obligation funds first; junior keeps the remainder.</div>
        </div>

        {/* Fee band */}
        <div className="chart-card reveal-up" style={{ animationDelay: "180ms" }}>
          <div className="chart-title">Dynamic fee band</div>
          <div className="feeband">
            <div className="feeband-track">
              <div className="feeband-range" />
              <div
                className="feeband-marker feeband-base"
                style={{ left: pos(p.baseFeeBps) }}
                title={`base ${(p.baseFeeBps / 100).toFixed(2)}%`}
              />
              <div
                className="feeband-marker feeband-next"
                style={{ left: pos(p.nextSwapFeeBps) }}
                title={`next swap ${(p.nextSwapFeeBps / 100).toFixed(2)}%`}
              />
            </div>
            <div className="feeband-ends">
              <span>min {(feeLo / 100).toFixed(2)}%</span>
              <span>max {(feeHi / 100).toFixed(2)}%</span>
            </div>
            {/* Labels live in a legend, not floating on the track, so close base/next values never overlap. */}
            <div className="feeband-legend">
              <span className="fb-leg">
                <span className="fb-dot fb-base" /> base <b>{(p.baseFeeBps / 100).toFixed(2)}%</b>
              </span>
              <span className="fb-leg">
                <span className="fb-dot fb-next" /> next swap <b>{(p.nextSwapFeeBps / 100).toFixed(2)}%</b>
              </span>
            </div>
          </div>
          <div className="reserve-mini">
            Token-backed reserve: <b>{fmt(toNum(p.reserveTokens))}</b> &middot; junior buffer{" "}
            <b>{fmt(toNum(p.juniorReserve))}</b>
          </div>
        </div>

        {/* Session sparkline */}
        <div className="chart-card chart-card-wide reveal-up" style={{ animationDelay: "240ms" }}>
          <div className="chart-title">
            Coverage ratio &middot; this session
            <span className="spark-live">
              <span className="spark-dot" /> live
            </span>
          </div>
          <Sparkline series={covSeries} color={covColor} />
          <div className="spark-foot">
            {covSeries.length} sample{covSeries.length === 1 ? "" : "s"} &middot; accumulates as the pool refreshes
          </div>
        </div>
      </div>
    </div>
  );
}

function WfBar({
  label,
  value,
  max,
  cls,
  fmt: fmtFn,
}: {
  label: string;
  value: number;
  max: number;
  cls: string;
  fmt: (n: number) => string;
}) {
  const pct = max > 0 ? Math.max(2, Math.min(100, (value / max) * 100)) : 2;
  return (
    <div className="wf-bar-row">
      <div className="wf-bar-label">{label}</div>
      <div className="wf-bar-track">
        <div className={`wf-bar-fill ${cls}`} style={{ width: `${pct}%` }} />
      </div>
      <div className="wf-bar-val mono">{fmtFn(value)}</div>
    </div>
  );
}

function Sparkline({ series, color }: { series: number[]; color: string }) {
  const W = 600;
  const H = 96;
  const pad = 8;
  if (series.length === 0) return <div className="spark-empty">Waiting for the first sample…</div>;
  const min = Math.min(...series);
  const max = Math.max(...series);
  const span = max - min || 1;
  const stepX = series.length > 1 ? (W - pad * 2) / (series.length - 1) : 0;
  const y = (v: number) => H - pad - ((v - min) / span) * (H - pad * 2);
  const pts = series.map((v, i) => `${pad + i * stepX},${y(v)}`);
  const line = `M ${pts.join(" L ")}`;
  const area = `${line} L ${pad + (series.length - 1) * stepX},${H - pad} L ${pad},${H - pad} Z`;
  const lastX = pad + (series.length - 1) * stepX;
  const lastY = y(series[series.length - 1]);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="spark" preserveAspectRatio="none">
      <defs>
        <linearGradient id="sparkfill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity="0.22" />
          <stop offset="100%" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={area} fill="url(#sparkfill)" />
      <path d={line} fill="none" stroke={color} strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />
      <circle cx={lastX} cy={lastY} r={3.5} fill={color} className="spark-head" />
    </svg>
  );
}
