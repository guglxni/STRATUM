/**
 * Coverage / waterfall simulator (spec §6.3). Reads the current pool's TVLs + coverage floor from
 * the hook and lets a judge enter hypothetical senior/junior deposits to see prospective coverage,
 * whether the senior intake would be blocked, and whether CoverageStress would fire. Pure math
 * (lib/coverageSim.ts), no transaction — labelled "simulation only".
 */

import { useMemo, useState } from "react";
import { useReadContract } from "wagmi";
import { formatUnits, parseUnits } from "viem";
import { STRATUM_HOOK_ABI } from "../abis/stratumHook";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../config/addresses";
import { simulate } from "../lib/coverageSim";

interface PoolStateLite {
  seniorTVL: bigint;
  juniorTVL: bigint;
  minCoverageRatioBps: number;
}

export default function CoverageSimulator({ poolId }: { poolId: string }) {
  const { data } = useReadContract({
    address: STRATUM_ADDRESSES.hook as `0x${string}`,
    abi: STRATUM_HOOK_ABI,
    functionName: "poolState",
    chainId: UNICHAIN_SEPOLIA.id,
    args: [poolId as `0x${string}`],
    query: { enabled: !!poolId && !!STRATUM_ADDRESSES.hook, refetchInterval: 15_000 },
  });

  const [senior, setSenior] = useState("10");
  const [junior, setJunior] = useState("0");

  const s = data as PoolStateLite | undefined;

  const result = useMemo(() => {
    if (!s) return null;
    try {
      return simulate(
        s.juniorTVL,
        s.seniorTVL,
        Number(s.minCoverageRatioBps),
        parseUnits(senior || "0", 18),
        parseUnits(junior || "0", 18)
      );
    } catch {
      return null;
    }
  }, [s, senior, junior]);

  if (!s) return null;

  const cur = Number((s.juniorTVL * 10_000n) / (s.seniorTVL === 0n ? 1n : s.seniorTVL));
  const floor = Number(s.minCoverageRatioBps);

  return (
    <div className="metric-card" style={{ marginBottom: 20 }}>
      <div className="metric-title" style={{ marginBottom: 4 }}>
        Coverage simulator <span className="badge badge-neutral">simulation only</span>
      </div>
      <p className="caption muted" style={{ marginBottom: 12 }}>
        The hook enforces coverage ≥ floor on every senior deposit. Test the inequality here — no
        transaction. Current coverage {(cur / 100).toFixed(1)}% · floor {(floor / 100).toFixed(1)}% · senior
        TVL {parseFloat(formatUnits(s.seniorTVL, 18)).toFixed(2)} · junior TVL{" "}
        {parseFloat(formatUnits(s.juniorTVL, 18)).toFixed(2)}.
      </p>
      <div className="lab-form">
        <label className="lab-field">
          <span>Hypothetical senior deposit</span>
          <input className="input-pill mono" value={senior} onChange={(e) => setSenior(e.target.value)} />
        </label>
        <label className="lab-field">
          <span>Hypothetical junior deposit</span>
          <input className="input-pill mono" value={junior} onChange={(e) => setJunior(e.target.value)} />
        </label>
      </div>
      {result && (
        <div className="sim-out">
          <div className="sim-item">
            <span className="sim-k">Prospective coverage</span>
            <span className="sim-v mono">{(result.prospectiveBps / 100).toFixed(1)}%</span>
          </div>
          <div className="sim-item">
            <span className="sim-k">Senior deposit</span>
            <span className={`badge ${result.seniorBlocked ? "badge-watch" : "badge-ok"}`}>
              {result.seniorBlocked ? "BLOCKED (below floor)" : "allowed"}
            </span>
          </div>
          <div className="sim-item">
            <span className="sim-k">CoverageStress would fire</span>
            <span className={`badge ${result.wouldEmitStress ? "badge-watch" : "badge-neutral"}`}>
              {result.wouldEmitStress ? `yes (stress ${result.stress})` : `no (stress ${result.stress})`}
            </span>
          </div>
        </div>
      )}
    </div>
  );
}
