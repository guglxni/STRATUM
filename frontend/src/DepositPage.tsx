/**
 * #deposit route (Phase E): tranche deposit / withdraw via StratumZap.
 */

import { useAccount, useConnect, useDisconnect } from "wagmi";
import DemoFaucet from "./components/DemoFaucet";
import DepositPanel from "./components/DepositPanel";
import JudgeQuickStartPanel from "./components/JudgeQuickStartPanel";

interface DepositPageProps {
  onBack: () => void;
  onDashboard: () => void;
}

export default function DepositPage({ onBack, onDashboard }: DepositPageProps) {
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();

  return (
    <div className="page-parchment">
      <nav className="gnav">
        <div className="container-wide gnav-inner">
          <button className="gnav-logo" onClick={onBack}>
            <span className="logo-mark" aria-hidden>
              <span />
              <span />
              <span />
            </span>
            STRATUM
          </button>
          <div className="gnav-links">
            <a
              href="#"
              onClick={(e) => {
                e.preventDefault();
                onBack();
              }}
            >
              About
            </a>
            <a
              href="#app"
              onClick={(e) => {
                e.preventDefault();
                onDashboard();
              }}
            >
              Dashboard
            </a>
            <a href="#positions">Positions</a>
            <a href="#labs">Labs</a>
            {isConnected ? (
              <>
                <span className="wallet-chip">
                  {address?.slice(0, 6)}…{address?.slice(-4)}
                </span>
                <button className="btn-utility" onClick={() => disconnect()}>
                  Disconnect
                </button>
              </>
            ) : (
              <div className="wallet-connect-group">
                {connectors.map((c) => (
                  <button key={c.uid} className="btn-utility" onClick={() => connect({ connector: c })}>
                    {c.name}
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>
      </nav>

      <main className="dash-main container">
        <div className="dash-header">
          <div>
            <h2>Deposit into a tranche</h2>
            <div className="sub">
              One transaction through StratumZap &middot; Permit2 signatures, classic approvals, or delivered balance
            </div>
          </div>
        </div>
        <JudgeQuickStartPanel defaultCollapsed />
        <DemoFaucet />
        <DepositPanel />
      </main>
    </div>
  );
}
