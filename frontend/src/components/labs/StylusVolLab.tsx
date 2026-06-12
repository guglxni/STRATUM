/**
 * Stylus Volatility Lab (spec §7.1): a judge enters a current EWMA and last trade size, clicks Run,
 * and gets a live ML volatility forecast straight from the Arbitrum Sepolia Stylus engine over
 * public RPC. This is the "convinced" interaction — a real cross-chain eth_call returning a number.
 */

import { useState } from "react";
import { formatUnits, parseUnits } from "viem";
import LabCard from "./LabCard";
import { useStylusForecast } from "../../hooks/useStylusForecast";
import { STRATUM_LIVE_MULTICHAIN } from "../../config/addresses";
import { explorerAddress, CHAIN_IDS } from "../../config/explorers";

export default function StylusVolLab() {
  const [ewma, setEwma] = useState("1.0");
  const [size, setSize] = useState("1.1");
  const { result, loading, error, run } = useStylusForecast();

  const submit = () => {
    try {
      run(parseUnits(ewma || "0", 18), parseUnits(size || "0", 18));
    } catch {
      /* invalid input; ignore */
    }
  };

  return (
    <LabCard
      protocol="Arbitrum Stylus"
      enables="Optional ML forward-volatility forecast that can override the hook's dynamic swap fee (FR-05)."
      trigger="Read-only eth_call to the Rust engine (activated WASM)."
      klass="R0"
      status="live"
      chainHint="Reading Arbitrum Sepolia"
      proofHref={explorerAddress(STRATUM_LIVE_MULTICHAIN.stylusEngineArbitrum, CHAIN_IDS.ARBITRUM_SEPOLIA)}
      proofLabel="Engine on Arbiscan"
    >
      <div className="lab-form">
        <label className="lab-field">
          <span>Current EWMA</span>
          <input className="input-pill mono" value={ewma} onChange={(e) => setEwma(e.target.value)} />
        </label>
        <label className="lab-field">
          <span>Last trade size</span>
          <input className="input-pill mono" value={size} onChange={(e) => setSize(e.target.value)} />
        </label>
        <button className="btn-pill btn-pill-sm" onClick={submit} disabled={loading}>
          {loading ? "Forecasting…" : "Run forecast"}
        </button>
      </div>
      {error && <p className="caption lab-err">Forecast failed: {error}</p>}
      {result !== undefined && !error && (
        <p className="lab-result">
          Forecast next-step volatility: <span className="mono">{formatUnits(result, 18)}</span>{" "}
          <span className="caption muted">(scaled 1e18; e.g. 1.0 / 1.1 → ~1.01)</span>
        </p>
      )}
    </LabCard>
  );
}
