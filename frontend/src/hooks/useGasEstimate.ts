/**
 * Live gas-cost estimate for a contract call, before the user signs anything.
 *
 * Estimates gas units via eth_estimateGas and multiplies by the current per-gas fee
 * (EIP-1559 maxFeePerGas, falling back to legacy gasPrice). Pinned to the primary chain so the
 * estimate is correct even when the wallet is sitting on a different network. Refetches on an
 * interval so the displayed cost tracks the live base fee.
 */

import { usePublicClient } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { formatEther, formatGwei, type Abi } from "viem";
import { UNICHAIN_SEPOLIA } from "../config/addresses";

export interface GasEstimate {
  /** Estimated gas units the call will consume. */
  gas?: bigint;
  /** Total estimated fee in wei (gas * fee-per-gas). */
  feeWei?: bigint;
  /** Total estimated fee as a decimal ETH string. */
  feeEth?: string;
  /** Effective per-gas fee in gwei (what the estimate multiplied by). */
  gwei?: string;
  isLoading: boolean;
  error: boolean;
}

export function useGasEstimate(params: {
  address?: `0x${string}`;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
  account?: `0x${string}`;
  enabled?: boolean;
}): GasEstimate {
  const { address, abi, functionName, args, account, enabled = true } = params;
  const client = usePublicClient({ chainId: UNICHAIN_SEPOLIA.id });

  const q = useQuery({
    queryKey: ["gas-estimate", UNICHAIN_SEPOLIA.id, address, functionName, account, args.map(String)],
    enabled: enabled && !!client && !!address && !!account,
    refetchInterval: 15_000,
    queryFn: async () => {
      if (!client || !address || !account) throw new Error("not ready");
      const gas = await client.estimateContractGas({
        address,
        abi,
        functionName,
        args,
        account,
      } as Parameters<typeof client.estimateContractGas>[0]);

      // EIP-1559 fee where supported; fall back to legacy gas price otherwise.
      let feePerGas: bigint;
      try {
        const fees = await client.estimateFeesPerGas();
        feePerGas = fees.maxFeePerGas ?? (await client.getGasPrice());
      } catch {
        feePerGas = await client.getGasPrice();
      }

      return { gas, feePerGas, feeWei: gas * feePerGas };
    },
  });

  if (!q.data) return { isLoading: q.isLoading, error: q.isError };

  return {
    gas: q.data.gas,
    feeWei: q.data.feeWei,
    feeEth: formatEther(q.data.feeWei),
    gwei: formatGwei(q.data.feePerGas),
    isLoading: q.isLoading,
    error: q.isError,
  };
}
