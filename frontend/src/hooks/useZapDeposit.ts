/**
 * Phase E (D-6): zap deposit/withdraw orchestration.
 *
 * Three funding modes, mirroring the committed StratumZap surface exactly:
 *  - "approve":   classic ERC-20 approve(zap) + zap.deposit (pull mode)
 *  - "permit2":   one-time approve(Permit2) per token, then signature-only deposits via
 *                 zap.depositWithPermit2 (PermitBatchTransferFrom over [currency0, currency1])
 *  - "delivered": zap.deposit with useDeliveredBalance=true; consumes tokens a Trading API swap
 *                 already delivered to the zap (custom-recipient flow)
 *
 * Safety rules (FRONTEND_UPGRADE_INSTRUCTIONS 8.4): signatures are built fresh per attempt with a
 * 30-minute deadline and never persisted; the zap refunds unused funding in the same transaction.
 */

import { useCallback, useState } from "react";
import { useAccount, useChainId, usePublicClient, useWalletClient } from "wagmi";
import { STRATUM_ZAP_ABI } from "../abis/stratumZap";
import { ERC20_ABI } from "../abis/erc20";
import { STRATUM_ADDRESSES } from "../config/addresses";
import type { PoolKeyStruct } from "../lib/poolKey";
import { PERMIT2_BATCH_TYPES, buildZapPermit, permit2Domain, permitToTypedMessage } from "../lib/permit2";

export type DepositMode = "approve" | "permit2" | "delivered";

export type FlowPhase = "idle" | "approving" | "signing" | "depositing" | "withdrawing" | "done" | "error";

export interface ZapFlowState {
  phase: FlowPhase;
  /** Human-readable progress / error line. */
  message: string;
  /** Last successful action's tx hash. */
  txHash?: `0x${string}`;
  /** Position id derived for the (zap, ticks, salt) tuple after a deposit. */
  positionId?: `0x${string}`;
}

export interface DepositArgs {
  poolKey: PoolKeyStruct;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  tranche: 0 | 1;
  userSalt: `0x${string}`;
  amount0Max: bigint;
  amount1Max: bigint;
  mode: DepositMode;
}

export interface WithdrawArgs {
  poolKey: PoolKeyStruct;
  tickLower: number;
  tickUpper: number;
  userSalt: `0x${string}`;
}

function errMessage(e: unknown): string {
  const m = e instanceof Error ? e.message : String(e);
  return m.length > 220 ? m.slice(0, 220) + "…" : m;
}

export function useZapDeposit() {
  const { address } = useAccount();
  const chainId = useChainId();
  const publicClient = usePublicClient();
  const { data: walletClient } = useWalletClient();

  const [state, setState] = useState<ZapFlowState>({ phase: "idle", message: "" });
  const zap = STRATUM_ADDRESSES.zap as `0x${string}`;
  const zapConfigured = !!STRATUM_ADDRESSES.zap;

  /** Ensure `spender` can pull `amount` of `token` from the user; sends approve only if short. */
  const ensureAllowance = useCallback(
    async (token: `0x${string}`, spender: `0x${string}`, amount: bigint) => {
      if (!publicClient || !walletClient || !address || amount === 0n) return;
      const current = (await publicClient.readContract({
        address: token,
        abi: ERC20_ABI,
        functionName: "allowance",
        args: [address, spender],
      })) as bigint;
      if (current >= amount) return;
      const hash = await walletClient.writeContract({
        address: token,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [spender, amount],
      });
      await publicClient.waitForTransactionReceipt({ hash });
    },
    [publicClient, walletClient, address]
  );

  const deposit = useCallback(
    async (args: DepositArgs) => {
      if (!zapConfigured || !publicClient || !walletClient || !address) {
        setState({ phase: "error", message: "Connect a wallet and configure the zap address first." });
        return;
      }
      const { poolKey, tickLower, tickUpper, liquidity, tranche, userSalt, amount0Max, amount1Max, mode } = args;
      try {
        let hash: `0x${string}`;

        if (mode === "permit2") {
          // One-time Permit2 setup per token, then signature-only transfers thereafter.
          setState({ phase: "approving", message: "Checking one-time Permit2 token approvals…" });
          const permit2 = STRATUM_ADDRESSES.permit2 as `0x${string}`;
          await ensureAllowance(poolKey.currency0, permit2, amount0Max);
          await ensureAllowance(poolKey.currency1, permit2, amount1Max);

          setState({ phase: "signing", message: "Sign the Permit2 transfer in your wallet…" });
          const permit = buildZapPermit(poolKey.currency0, amount0Max, poolKey.currency1, amount1Max);
          const signature = await walletClient.signTypedData({
            domain: permit2Domain(chainId),
            types: PERMIT2_BATCH_TYPES,
            primaryType: "PermitBatchTransferFrom",
            message: permitToTypedMessage(permit, zap),
          });

          setState({ phase: "depositing", message: "Submitting depositWithPermit2…" });
          hash = await walletClient.writeContract({
            address: zap,
            abi: STRATUM_ZAP_ABI,
            functionName: "depositWithPermit2",
            args: [poolKey, tickLower, tickUpper, liquidity, tranche, userSalt, permit, signature],
          });
        } else {
          if (mode === "approve") {
            setState({ phase: "approving", message: "Approving the zap to pull funding…" });
            await ensureAllowance(poolKey.currency0, zap, amount0Max);
            await ensureAllowance(poolKey.currency1, zap, amount1Max);
          }
          setState({ phase: "depositing", message: "Submitting deposit…" });
          hash = await walletClient.writeContract({
            address: zap,
            abi: STRATUM_ZAP_ABI,
            functionName: "deposit",
            args: [
              poolKey,
              tickLower,
              tickUpper,
              liquidity,
              tranche,
              userSalt,
              mode === "delivered" ? 0n : amount0Max,
              mode === "delivered" ? 0n : amount1Max,
              mode === "delivered",
            ],
          });
        }

        await publicClient.waitForTransactionReceipt({ hash });

        // positionId = keccak256(abi.encode(zap, tickLower, tickUpper, keccak256(abi.encode(user, userSalt))))
        // Reading it back from the recorded owner mapping avoids re-implementing the preimage here.
        const { encodeAbiParameters, keccak256 } = await import("viem");
        const zapSalt = keccak256(
          encodeAbiParameters([{ type: "address" }, { type: "bytes32" }], [address, userSalt])
        );
        const positionId = keccak256(
          encodeAbiParameters(
            [{ type: "address" }, { type: "int24" }, { type: "int24" }, { type: "bytes32" }],
            [zap, tickLower, tickUpper, zapSalt]
          )
        );

        setState({ phase: "done", message: "Position opened.", txHash: hash, positionId });
      } catch (e) {
        setState({ phase: "error", message: errMessage(e) });
      }
    },
    [zapConfigured, publicClient, walletClient, address, chainId, zap, ensureAllowance]
  );

  const withdraw = useCallback(
    async (args: WithdrawArgs) => {
      if (!zapConfigured || !publicClient || !walletClient || !address) {
        setState({ phase: "error", message: "Connect a wallet and configure the zap address first." });
        return;
      }
      try {
        setState({ phase: "withdrawing", message: "Closing the position…" });
        const hash = await walletClient.writeContract({
          address: zap,
          abi: STRATUM_ZAP_ABI,
          functionName: "withdraw",
          args: [args.poolKey, args.tickLower, args.tickUpper, args.userSalt],
        });
        await publicClient.waitForTransactionReceipt({ hash });
        setState({ phase: "done", message: "Position closed; proceeds delivered to your wallet.", txHash: hash });
      } catch (e) {
        setState({ phase: "error", message: errMessage(e) });
      }
    },
    [zapConfigured, publicClient, walletClient, address, zap]
  );

  const reset = useCallback(() => setState({ phase: "idle", message: "" }), []);

  return { state, deposit, withdraw, reset, zapConfigured };
}
