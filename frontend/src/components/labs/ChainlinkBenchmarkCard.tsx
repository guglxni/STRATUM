/**
 * Chainlink Benchmark reader (spec §11.1). Reads Chainlink AggregatorV3 Data Feeds on Ethereum
 * Sepolia over public RPC and shows the latest answer per pair. The senior target rate (FR-25) uses
 * ETH/USD; the extra pairs demonstrate the same read path generalizes across feeds. Disclaimer: the
 * benchmark informs the senior target rate only, never the IL accounting (golden rule 2).
 */

import { useState } from "react";
import { formatUnits } from "viem";
import LabCard from "./LabCard";
import { readClient } from "../../lib/readClients";
import { AGGREGATOR_V3_ABI } from "../../abis/aggregatorV3";
import { CHAINLINK_SEPOLIA_FEEDS } from "../../config/addresses";
import { explorerAddress, CHAIN_IDS } from "../../config/explorers";

interface Quote {
  pair: string;
  address: string;
  price: string;
  updatedAt: number;
}

/** Prices near 1 (stables / FX / JPY) need more precision than the 2dp used for ETH/BTC. */
function formatPrice(value: number): string {
  const small = value < 10;
  return value.toLocaleString(undefined, {
    minimumFractionDigits: small ? 4 : 2,
    maximumFractionDigits: small ? 4 : 2,
  });
}

export default function ChainlinkBenchmarkCard() {
  const [quotes, setQuotes] = useState<Quote[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");

  const readAll = async () => {
    setBusy(true);
    setErr("");
    try {
      const client = readClient(CHAIN_IDS.ETHEREUM_SEPOLIA);
      // One AggregatorV3 read path, fanned across every verified feed. Settle independently so a
      // single slow/missing feed can't blank the whole table.
      const results = await Promise.allSettled(
        CHAINLINK_SEPOLIA_FEEDS.map(async (f): Promise<Quote> => {
          const addr = f.address as `0x${string}`;
          const [round, decimals] = await Promise.all([
            client.readContract({ address: addr, abi: AGGREGATOR_V3_ABI, functionName: "latestRoundData" }),
            client.readContract({ address: addr, abi: AGGREGATOR_V3_ABI, functionName: "decimals" }),
          ]);
          const [, answer, , updated] = round as readonly [bigint, bigint, bigint, bigint, bigint];
          const value = parseFloat(formatUnits(answer, Number(decimals)));
          return { pair: f.pair, address: f.address, price: formatPrice(value), updatedAt: Number(updated) };
        })
      );
      const ok = results.filter((r): r is PromiseFulfilledResult<Quote> => r.status === "fulfilled").map((r) => r.value);
      if (!ok.length) throw new Error("no feeds responded");
      setQuotes(ok);
    } catch (e) {
      setErr(e instanceof Error ? e.message.slice(0, 140) : "read failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <LabCard
      protocol="Chainlink"
      enables="Optional benchmark for the senior target rate (FR-25). Never touches IL accounting."
      trigger={`Read latestRoundData() across ${CHAINLINK_SEPOLIA_FEEDS.length} ETH/USD-style feeds.`}
      klass="R0"
      status="live"
      chainHint="Reading Ethereum Sepolia"
      proofHref={explorerAddress(CHAINLINK_SEPOLIA_FEEDS[0].address, CHAIN_IDS.ETHEREUM_SEPOLIA)}
      proofLabel="ETH/USD feed on Etherscan"
    >
      <button className="btn-pill btn-pill-sm" onClick={readAll} disabled={busy}>
        {busy ? "Reading…" : `Read ${CHAINLINK_SEPOLIA_FEEDS.length} feeds`}
      </button>
      {err && <p className="caption lab-err">{err}</p>}

      {quotes.length > 0 && (
        <div className="cl-feeds">
          {quotes.map((q) => (
            <a
              key={q.pair}
              className="cl-feed"
              href={explorerAddress(q.address, CHAIN_IDS.ETHEREUM_SEPOLIA)}
              target="_blank"
              rel="noreferrer"
              title={`${q.address} · updated ${new Date(q.updatedAt * 1000).toLocaleString()}`}
            >
              <span className="cl-pair">{q.pair}</span>
              <span className="cl-price mono">
                {q.pair === "ETH/USD" ? "★ " : ""}
                {q.price}
              </span>
            </a>
          ))}
        </div>
      )}

      <p className="fine-print" style={{ marginTop: 10 }}>
        Same <span className="mono">AggregatorV3.latestRoundData()</span> path on every pair. ★ ETH/USD
        feeds the senior coupon target; the rest are shown to prove the read generalizes. IL is computed
        from pool tick deltas, with no oracle in the path.
      </p>
    </LabCard>
  );
}
