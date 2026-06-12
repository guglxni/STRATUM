/**
 * PoolKey construction for the demo pool (Phase C, FRONTEND_UPGRADE_INSTRUCTIONS 6.2).
 *
 * The v4 PoolKey is (currency0, currency1, fee, tickSpacing, hooks). The demo pool is created by
 * script/InitStratumPool.s.sol with the dynamic-fee flag and tickSpacing 60; both are overridable
 * via env so the UI can point at any STRATUM pool without a code change.
 */

import { STRATUM_ADDRESSES } from "../config/addresses";

export interface PoolKeyStruct {
  currency0: `0x${string}`;
  currency1: `0x${string}`;
  fee: number;
  tickSpacing: number;
  hooks: `0x${string}`;
}

/** Sort two token addresses into v4 (currency0 < currency1) order. */
export function sortCurrencies(a: string, b: string): [`0x${string}`, `0x${string}`] {
  return a.toLowerCase() < b.toLowerCase()
    ? [a as `0x${string}`, b as `0x${string}`]
    : [b as `0x${string}`, a as `0x${string}`];
}

/** Build the demo pool's PoolKey from config. Returns null when required addresses are unset. */
export function buildDemoPoolKey(): PoolKeyStruct | null {
  const { demoToken0, demoToken1, hook, demoPoolFee, demoPoolTickSpacing } = STRATUM_ADDRESSES;
  if (!demoToken0 || !demoToken1 || !hook) return null;
  const [currency0, currency1] = sortCurrencies(demoToken0, demoToken1);
  return {
    currency0,
    currency1,
    fee: demoPoolFee,
    tickSpacing: demoPoolTickSpacing,
    hooks: hook as `0x${string}`,
  };
}
