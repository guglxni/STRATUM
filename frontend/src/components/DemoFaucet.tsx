/**
 * Testnet demo-token faucet. Calls the public `faucet(to, amount)` on each DemoToken ERC-20
 * deployed by DemoLifecycle.s.sol. STRATUM core does not mint pool assets; these are separate
 * test currencies (sdA / sdB) used only to fund zap deposits on Unichain Sepolia.
 */

import { useCallback, useEffect, useState } from "react";
import {
  useAccount,
  useBalance,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { formatEther, formatUnits, parseEther, parseUnits } from "viem";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../config/addresses";
import { DEMO_TOKEN_ABI } from "../abis/demoToken";
import { GAS_FAUCET_URL, BRIDGE_URL } from "./BalancesStrip";
import { useGasEstimate } from "../hooks/useGasEstimate";

const EXPLORER = UNICHAIN_SEPOLIA.blockExplorers.default.url;
const FAUCET_AMOUNT = parseUnits("1000", 18);
const LOW_GAS = parseEther("0.0005");

/** Render a tiny ETH fee with enough precision for testnet-scale costs, trimming trailing zeros. */
function fmtEthFee(s: string | undefined): string {
  if (s === undefined) return "—";
  const n = parseFloat(s);
  if (n === 0) return "0";
  if (n < 1e-9) return "<0.000000001";
  return n.toFixed(9).replace(/0+$/, "").replace(/\.$/, "");
}

function fmtBal(v: bigint | undefined): string {
  if (v === undefined) return "—";
  const f = parseFloat(formatUnits(v, 18));
  if (f === 0) return "0";
  if (f < 0.01) return "<0.01";
  if (f < 1_000) return f.toFixed(2);
  return (f / 1_000).toFixed(2) + "K";
}

function TokenRow({
  token,
  symbol,
  balance,
  busy,
  onMint,
}: {
  token: `0x${string}`;
  symbol: string;
  balance: bigint | undefined;
  busy: boolean;
  onMint: () => void;
}) {
  return (
    <div className="faucet-row">
      <div>
        <div className="metric-title">{symbol}</div>
        <div className="caption mono muted">{token.slice(0, 10)}…</div>
        <div className="caption" style={{ marginTop: 4 }}>
          Balance: <span className="mono">{fmtBal(balance)}</span> {symbol}
        </div>
      </div>
      <button className="btn-pill btn-pill-sm" disabled={busy} onClick={onMint}>
        Mint 1,000
      </button>
    </div>
  );
}

export default function DemoFaucet() {
  // useAccount().chainId is the wallet/connector's ACTUAL chain (reports unconfigured chains too);
  // useChainId() clamps to a configured chain, so it can never detect a wrong-network state here.
  const { address, isConnected, chainId } = useAccount();
  const token0 = STRATUM_ADDRESSES.demoToken0 as `0x${string}`;
  const token1 = STRATUM_ADDRESSES.demoToken1 as `0x${string}`;
  const configured = !!STRATUM_ADDRESSES.demoToken0 && !!STRATUM_ADDRESSES.demoToken1;

  const [status, setStatus] = useState("");

  const { data: sym0 } = useReadContract({
    address: token0,
    abi: DEMO_TOKEN_ABI,
    functionName: "symbol",
    chainId: UNICHAIN_SEPOLIA.id,
    query: { enabled: configured },
  });
  const { data: sym1 } = useReadContract({
    address: token1,
    abi: DEMO_TOKEN_ABI,
    functionName: "symbol",
    chainId: UNICHAIN_SEPOLIA.id,
    query: { enabled: configured },
  });
  const { data: bal0, refetch: refetch0 } = useReadContract({
    address: token0,
    abi: DEMO_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: UNICHAIN_SEPOLIA.id,
    query: { enabled: configured && !!address },
  });
  const { data: bal1, refetch: refetch1 } = useReadContract({
    address: token1,
    abi: DEMO_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: UNICHAIN_SEPOLIA.id,
    query: { enabled: configured && !!address },
  });

  const { data: ethBal } = useBalance({ address, chainId: UNICHAIN_SEPOLIA.id, query: { enabled: !!address, refetchInterval: 10_000 } });

  // Live gas-cost estimate for one mint. Both tokens are identical DemoToken contracts, so token0 is
  // representative. Pinned to Unichain in the hook, so it works even if the wallet is on another chain.
  const gasEst = useGasEstimate({
    address: token0,
    abi: DEMO_TOKEN_ABI,
    functionName: "faucet",
    args: address ? [address, FAUCET_AMOUNT] : [],
    account: address,
    enabled: configured && !!address,
  });

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash });

  const busy = isPending || confirming;
  const wrongNetwork = isConnected && chainId !== UNICHAIN_SEPOLIA.id;
  const lowGas = ethBal !== undefined && ethBal.value < LOW_GAS;
  const ethStr = ethBal ? Number(formatEther(ethBal.value)).toFixed(4) : "—";

  useEffect(() => {
    if (isSuccess && txHash) {
      refetch0();
      refetch1();
      setStatus(`Minted successfully.`);
    }
  }, [isSuccess, txHash, refetch0, refetch1]);

  const mint = useCallback(
    (token: `0x${string}`, label: string) => {
      if (!address || wrongNetwork) return;
      setStatus(`Confirm mint for ${label} in your wallet…`);
      reset();
      writeContract(
        {
          address: token,
          abi: DEMO_TOKEN_ABI,
          functionName: "faucet",
          args: [address, FAUCET_AMOUNT],
        },
        {
          onError: (e) => setStatus(e.message.slice(0, 200)),
        }
      );
    },
    [address, wrongNetwork, reset, writeContract]
  );

  if (!configured) return null;

  const label0 = (sym0 as string) ?? "token0";
  const label1 = (sym1 as string) ?? "token1";

  return (
    <div className="metric-card" style={{ marginBottom: 20 }}>
      <div className="metric-title" style={{ marginBottom: 4 }}>
        Demo token faucet &middot; mints 1,000 per click
      </div>
      <p className="caption muted" style={{ marginBottom: 14 }}>
        Pool assets are testnet ERC-20s with a public <span className="mono">faucet</span> mint (not part of the hook).
        Each click mints <b>1,000</b> tokens to your wallet. Mint {label0 || "sdA"} and {label1 || "sdB"} here before
        depositing - and keep some Unichain Sepolia ETH for gas.
      </p>

      {isConnected && (
        <div className="gas-estimate" aria-live="polite">
          <span className="gas-estimate-label">Est. gas per mint</span>
          {gasEst.error ? (
            <span className="gas-estimate-val muted">unavailable</span>
          ) : gasEst.feeEth === undefined ? (
            <span className="gas-estimate-val muted">estimating…</span>
          ) : (
            <span className="gas-estimate-val mono">
              ~{fmtEthFee(gasEst.feeEth)} ETH
              <span className="gas-estimate-detail">
                {" "}
                ({Number(gasEst.gas).toLocaleString()} gas · {Number(gasEst.gwei).toFixed(4)} gwei)
              </span>
            </span>
          )}
        </div>
      )}

      {wrongNetwork && (
        <div className="notice notice-error" style={{ marginBottom: 12 }}>
          Wrong network. Switch to {UNICHAIN_SEPOLIA.name} (chain ID {UNICHAIN_SEPOLIA.id}).
        </div>
      )}

      {!isConnected ? (
        <div className="notice">Connect a wallet above to mint demo tokens.</div>
      ) : (
        <>
          <TokenRow
            token={token0}
            symbol={label0}
            balance={bal0 as bigint | undefined}
            busy={busy || wrongNetwork}
            onMint={() => mint(token0, label0)}
          />
          <TokenRow
            token={token1}
            symbol={label1}
            balance={bal1 as bigint | undefined}
            busy={busy || wrongNetwork}
            onMint={() => mint(token1, label1)}
          />
          <div className="faucet-row">
            <div>
              <div className="metric-title">ETH <span style={{ fontWeight: 400, opacity: 0.6, fontSize: "0.8em" }}>({UNICHAIN_SEPOLIA.name})</span></div>
              <div className="caption" style={{ marginTop: 4 }}>
                Balance: <span className="mono">{ethStr}</span> ETH
              </div>
            </div>
            <div className="faucet-eth-actions">
              {lowGas ? (
                <a className="btn-pill-ghost btn-pill-ghost-sm" href={GAS_FAUCET_URL} target="_blank" rel="noreferrer">
                  Get test ETH ↗
                </a>
              ) : (
                <span className="badge badge-ok">enough for gas</span>
              )}
              <a className="link-subtle" href={BRIDGE_URL} target="_blank" rel="noreferrer">
                Bridge from Sepolia ↗
              </a>
            </div>
          </div>
        </>
      )}

      {status && (
        <p className="caption" style={{ marginTop: 12 }}>
          {status}
          {txHash && (
            <>
              {" "}
              <a className="mono" href={`${EXPLORER}/tx/${txHash}`} target="_blank" rel="noreferrer">
                View tx
              </a>
            </>
          )}
        </p>
      )}
    </div>
  );
}
