/**
 * Judge quick-start panel (spec §5.6): a collapsible card giving a cold-start judge everything to
 * complete a deposit without leaving the page or reading the repo - network add button, gas/bridge
 * links, on-page faucet pointer, recommended deposit params, the seeded demo pool id, and proof
 * links (including the presenter's last tx when one is stashed this session).
 */

import { useEffect, useState } from "react";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../config/addresses";
import { explorerAddress, explorerTx } from "../config/explorers";
import { addUnichainChain } from "../lib/addUnichainChain";
import { GAS_FAUCET_URL, BRIDGE_URL } from "./BalancesStrip";
import { readDepositStash } from "../lib/depositStash";

interface Props {
  /** Navigate to the deposit route; when absent (already on #deposit) the button is hidden. */
  onGoDeposit?: () => void;
  /** Start collapsed (e.g. on #deposit where the faucet is already visible). */
  defaultCollapsed?: boolean;
}

export default function JudgeQuickStartPanel({ onGoDeposit, defaultCollapsed = false }: Props) {
  const [open, setOpen] = useState(!defaultCollapsed);
  const [netMsg, setNetMsg] = useState("");
  const [lastTx, setLastTx] = useState<`0x${string}` | undefined>();

  useEffect(() => {
    setLastTx(readDepositStash()?.txHash);
  }, []);

  const addNetwork = async () => {
    setNetMsg("");
    try {
      await addUnichainChain();
      setNetMsg(`${UNICHAIN_SEPOLIA.name} added / selected in your wallet.`);
    } catch (e) {
      setNetMsg(e instanceof Error ? e.message : "Could not add the network.");
    }
  };

  const poolId = STRATUM_ADDRESSES.defaultPoolId;

  return (
    <div className="quickstart">
      <button className="quickstart-head" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span className="quickstart-badge">Judge quick-start</span>
        <span className="quickstart-sub">Deposit in under 10 minutes — network, gas, params, proof links</span>
        <span className="quickstart-chev" aria-hidden>
          {open ? "▾" : "▸"}
        </span>
      </button>

      {open && (
        <div className="quickstart-body">
          <ol className="quickstart-steps">
            <li>
              <strong>Network.</strong> {UNICHAIN_SEPOLIA.name} (chain ID {UNICHAIN_SEPOLIA.id}), RPC{" "}
              <span className="mono">{UNICHAIN_SEPOLIA.rpcUrls.default.http[0]}</span>.
              <div className="quickstart-actions">
                <button className="btn-pill btn-pill-sm" onClick={addNetwork}>
                  Add {UNICHAIN_SEPOLIA.name} to wallet
                </button>
                {netMsg && <span className="caption muted">{netMsg}</span>}
              </div>
            </li>
            <li>
              <strong>Gas.</strong> Native {UNICHAIN_SEPOLIA.name} ETH pays for every tx.{" "}
              <a href={GAS_FAUCET_URL} target="_blank" rel="noreferrer">
                Faucet ↗
              </a>{" "}
              ·{" "}
              <a href={BRIDGE_URL} target="_blank" rel="noreferrer">
                Bridge from Sepolia ↗
              </a>
            </li>
            <li>
              <strong>Demo tokens.</strong> Use the on-page faucet (sdA / sdB, 1,000 per click) on the{" "}
              {onGoDeposit ? (
                <button className="link-inline" onClick={onGoDeposit}>
                  deposit page
                </button>
              ) : (
                "deposit page above"
              )}
              .
            </li>
            <li>
              <strong>Recommended deposit.</strong> Tranche <span className="mono">stLP (senior)</span>, ticks{" "}
              <span className="mono">-600 / 600</span>, salt <span className="mono">judge-1</span>, liquidity{" "}
              <span className="mono">1e18</span>, max spend <span className="mono">10 / 10</span>.
            </li>
            <li>
              <strong>Demo pool.</strong> <span className="mono">{poolId.slice(0, 18)}…</span> (fully seeded — avoid
              empty secondary pools).
            </li>
            <li>
              <strong>Verify it yourself.</strong>{" "}
              <a href={explorerAddress(STRATUM_ADDRESSES.hook)} target="_blank" rel="noreferrer">
                Hook ↗
              </a>{" "}
              ·{" "}
              <a href={explorerAddress(STRATUM_ADDRESSES.lens)} target="_blank" rel="noreferrer">
                Lens ↗
              </a>{" "}
              ·{" "}
              <a href={explorerAddress(STRATUM_ADDRESSES.zap)} target="_blank" rel="noreferrer">
                Zap ↗
              </a>
              {lastTx && (
                <>
                  {" "}
                  ·{" "}
                  <a href={explorerTx(lastTx)} target="_blank" rel="noreferrer">
                    your last deposit ↗
                  </a>
                </>
              )}
            </li>
          </ol>
          {onGoDeposit && (
            <button className="btn-pill" onClick={onGoDeposit}>
              Go to deposit →
            </button>
          )}
        </div>
      )}
    </div>
  );
}
