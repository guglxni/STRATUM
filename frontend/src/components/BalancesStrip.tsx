/**
 * Compact wallet-balances strip: the two demo pool tokens (sdA / sdB) plus the native ETH used for
 * gas, with a faucet link when gas is low. Surfaced on the deposit flow so the amounts a user has -
 * and the gas they need - are always visible, not hidden behind a wallet popup.
 */

import { useAccount, useBalance, useReadContract } from "wagmi";
import { formatEther, formatUnits, parseEther } from "viem";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../config/addresses";
import { DEMO_TOKEN_ABI } from "../abis/demoToken";

// `process.env` is statically replaced at build time (see vite.config.ts); this is just the type.
declare const process: { env: Record<string, string | undefined> };

// Two ways to get Unichain Sepolia gas ETH; both env-overridable so a different network deployment
// can point them elsewhere without touching code.
//  - Faucet: mint directly. The Unichain docs page lists the working faucets.
//  - Bridge: move existing Ethereum Sepolia ETH across (the screenshot case - plenty of Sepolia ETH,
//    little Unichain ETH). Defaults to the canonical Superchain testnet bridge.
export const GAS_FAUCET_URL =
  process.env.NEXT_PUBLIC_GAS_FAUCET_URL || "https://docs.unichain.org/docs/tools/faucets";
export const BRIDGE_URL =
  process.env.NEXT_PUBLIC_BRIDGE_URL || "https://testnets.superbridge.app";
const LOW_GAS = parseEther("0.0005");

function fmtToken(v: bigint | undefined): string {
  if (v === undefined) return "—";
  const f = parseFloat(formatUnits(v, 18));
  if (f === 0) return "0";
  if (f < 0.01) return "<0.01";
  if (f < 1_000) return f.toFixed(2);
  return (f / 1_000).toFixed(2) + "K";
}

export default function BalancesStrip() {
  const { address, isConnected } = useAccount();
  const t0 = STRATUM_ADDRESSES.demoToken0 as `0x${string}`;
  const t1 = STRATUM_ADDRESSES.demoToken1 as `0x${string}`;
  const configured = !!STRATUM_ADDRESSES.demoToken0 && !!STRATUM_ADDRESSES.demoToken1;

  const { data: sym0 } = useReadContract({ address: t0, abi: DEMO_TOKEN_ABI, functionName: "symbol", chainId: UNICHAIN_SEPOLIA.id, query: { enabled: configured } });
  const { data: sym1 } = useReadContract({ address: t1, abi: DEMO_TOKEN_ABI, functionName: "symbol", chainId: UNICHAIN_SEPOLIA.id, query: { enabled: configured } });
  const { data: bal0 } = useReadContract({
    address: t0,
    abi: DEMO_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: UNICHAIN_SEPOLIA.id,
    query: { enabled: configured && !!address, refetchInterval: 10_000 },
  });
  const { data: bal1 } = useReadContract({
    address: t1,
    abi: DEMO_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: UNICHAIN_SEPOLIA.id,
    query: { enabled: configured && !!address, refetchInterval: 10_000 },
  });
  const { data: eth } = useBalance({ address, chainId: UNICHAIN_SEPOLIA.id, query: { enabled: !!address, refetchInterval: 10_000 } });

  if (!isConnected || !configured) return null;

  const lowGas = eth !== undefined && eth.value < LOW_GAS;
  const ethStr = eth ? Number(formatEther(eth.value)).toFixed(4) : "—";

  return (
    <div className="bal-strip">
      <span className="bal-strip-label">Your balances</span>
      <div className="bal-item">
        <span className="bal-k">{(sym0 as string) ?? "sdA"}</span>
        <span className="bal-v mono">{fmtToken(bal0 as bigint | undefined)}</span>
      </div>
      <div className="bal-item">
        <span className="bal-k">{(sym1 as string) ?? "sdB"}</span>
        <span className="bal-v mono">{fmtToken(bal1 as bigint | undefined)}</span>
      </div>
      <div className={`bal-item${lowGas ? " bal-item-warn" : ""}`}>
        <span className="bal-k">ETH <span className="bal-chain-hint">({UNICHAIN_SEPOLIA.name})</span></span>
        <span className="bal-v mono">{ethStr}</span>
      </div>
      {lowGas && (
        <span className="bal-links">
          <a className="bal-faucet" href={GAS_FAUCET_URL} target="_blank" rel="noreferrer">
            Low gas - faucet ↗
          </a>
          <a className="bal-faucet" href={BRIDGE_URL} target="_blank" rel="noreferrer">
            bridge from Sepolia ↗
          </a>
        </span>
      )}
    </div>
  );
}
