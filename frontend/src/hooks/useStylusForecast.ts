/**
 * Stylus Volatility Lab read (spec §7.1). Calls forecastVolatility(currentEwma, lastTradeSize) on
 * the Arbitrum Sepolia Stylus engine over public RPC — no wallet, no network switch. Imperative
 * (runs on button click) so a judge sees a deliberate request → live result.
 */

import { useCallback, useState } from "react";
import { readClient } from "../lib/readClients";
import { STYLUS_ENGINE_ABI } from "../abis/stylusEngine";
import { STRATUM_LIVE_MULTICHAIN } from "../config/addresses";
import { CHAIN_IDS } from "../config/explorers";

export interface StylusForecastState {
  result?: bigint;
  loading: boolean;
  error?: string;
}

export function useStylusForecast() {
  const [state, setState] = useState<StylusForecastState>({ loading: false });

  const run = useCallback(async (currentEwma: bigint, lastTradeSize: bigint) => {
    setState({ loading: true });
    try {
      const client = readClient(CHAIN_IDS.ARBITRUM_SEPOLIA);
      const result = (await client.readContract({
        address: STRATUM_LIVE_MULTICHAIN.stylusEngineArbitrum as `0x${string}`,
        abi: STYLUS_ENGINE_ABI,
        functionName: "forecastVolatility",
        args: [currentEwma, lastTradeSize],
      })) as bigint;
      setState({ loading: false, result });
    } catch (e) {
      setState({ loading: false, error: e instanceof Error ? e.message.slice(0, 160) : "forecast failed" });
    }
  }, []);

  return { ...state, run };
}
