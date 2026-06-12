/**
 * Shared top nav for the secondary routes (#positions, #labs). Self-contained: links are plain hash
 * anchors that App's hashchange listener routes, and wallet connect/disconnect uses wagmi directly.
 * Keeps nav consistent without prop-drilling navigation callbacks.
 */

import { useAccount, useConnect, useDisconnect } from "wagmi";
import LogoMark from "./LogoMark";

const LINKS: { href: string; label: string; key: string }[] = [
  { href: "#", label: "About", key: "landing" },
  { href: "#app", label: "Dashboard", key: "app" },
  { href: "#positions", label: "Positions", key: "positions" },
  { href: "#labs", label: "Labs", key: "labs" },
  { href: "#deposit", label: "Deposit", key: "deposit" },
];

export default function PageNav({ active }: { active: string }) {
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();

  return (
    <nav className="gnav">
      <div className="container-wide gnav-inner">
        <a className="gnav-logo" href="#">
          <LogoMark variant="dark" />
          STRATUM
        </a>
        <div className="gnav-links">
          {LINKS.map((l) => (
            <a key={l.key} href={l.href} className={active === l.key ? "gnav-active" : undefined}>
              {l.label}
            </a>
          ))}
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
  );
}
