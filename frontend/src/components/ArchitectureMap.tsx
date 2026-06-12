/**
 * Multi-chain architecture map (spec §6.5): a static CSS diagram of STRATUM's topology — the
 * Unichain hook at the centre, Reactive RSCs automating it on Lasna, and the cross-chain reach to
 * Across (Sepolia) and Stylus (Arbitrum). No chart library; nodes link to explorers. Matches
 * docs/ARCHITECTURE.md, it does not invent a new architecture.
 */

import { STRATUM_ADDRESSES, STRATUM_LIVE_MULTICHAIN } from "../config/addresses";
import { explorerAddress, CHAIN_IDS } from "../config/explorers";

function Node({ label, sub, addr, chainId }: { label: string; sub: string; addr: string; chainId: number }) {
  return (
    <a className="arch-node" href={explorerAddress(addr, chainId)} target="_blank" rel="noreferrer">
      <span className="arch-node-label">{label}</span>
      <span className="arch-node-sub">{sub}</span>
    </a>
  );
}

export default function ArchitectureMap() {
  return (
    <div className="metric-card" style={{ marginBottom: 24 }}>
      <div className="metric-title" style={{ marginBottom: 4 }}>
        Architecture at a glance
      </div>
      <p className="caption muted" style={{ marginBottom: 16 }}>
        The core hook stands alone; peripherals are coordinated by Reactive and reach other chains. Click any
        node to open its explorer.
      </p>
      <div className="arch-map">
        <div className="arch-col">
          <Node label="Uniswap v4 + StratumHook" sub="Unichain Sepolia · core tranching" addr={STRATUM_ADDRESSES.hook} chainId={CHAIN_IDS.UNICHAIN_SEPOLIA} />
        </div>
        <div className="arch-arrow" aria-hidden>
          events →
        </div>
        <div className="arch-col">
          <Node label="Reactive RSCs" sub="Lasna · subscribed to hook events" addr={STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler} chainId={CHAIN_IDS.REACTIVE_LASNA} />
          <Node label="CPHR → Across" sub="→ Ethereum Sepolia reserves" addr={STRATUM_ADDRESSES.cphr} chainId={CHAIN_IDS.UNICHAIN_SEPOLIA} />
          <Node label="StylusShim → ML engine" sub="→ Arbitrum Sepolia vol forecast" addr={STRATUM_LIVE_MULTICHAIN.stylusEngineArbitrum} chainId={CHAIN_IDS.ARBITRUM_SEPOLIA} />
        </div>
        <div className="arch-arrow" aria-hidden>
          callback →
        </div>
        <div className="arch-col">
          <Node label="Unichain twins" sub="EpochSettler / CoverageMonitor / ReserveBalancer" addr={STRATUM_ADDRESSES.epochSettler} chainId={CHAIN_IDS.UNICHAIN_SEPOLIA} />
        </div>
      </div>
    </div>
  );
}
