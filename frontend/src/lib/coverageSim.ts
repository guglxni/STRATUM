/**
 * Pure client-side mirror of CoverageRatio.sol (spec §6.3 / §4.3). Lets a judge test the coverage
 * inequality the hook enforces on every senior deposit — no transaction, no re-implementation of IL
 * math. Formulas match the Solidity exactly (bigint, integer division) so results line up with cast.
 */

const UINT16_MAX = 65535;
const STRESS_EMIT_THRESHOLD = 5000; // CoverageStress fires when stress level exceeds this (bps).

/** juniorTVL * 10000 / seniorTVL, clamped; uint16.max when seniorTVL == 0 (infinite coverage). */
export function ratioBps(juniorTVL: bigint, seniorTVL: bigint): number {
  if (seniorTVL === 0n) return UINT16_MAX;
  const r = (juniorTVL * 10_000n) / seniorTVL;
  return r > BigInt(UINT16_MAX) ? UINT16_MAX : Number(r);
}

/** Coverage after a senior deposit of `depositValue` (and optional junior add). */
export function prospectiveRatioBps(juniorTVL: bigint, seniorTVL: bigint, seniorDeposit: bigint): number {
  return ratioBps(juniorTVL, seniorTVL + seniorDeposit);
}

/** Stress level 0..10000; higher = closer to the floor. Mirrors CoverageRatio.stressLevel. */
export function stressLevel(ratio: number, minCoverageRatioBps: number): number {
  if (minCoverageRatioBps === 0) return 0;
  if (ratio >= minCoverageRatioBps * 2) return 0;
  if (ratio <= minCoverageRatioBps) return 10_000;
  const span = minCoverageRatioBps; // (2*min - min)
  const excess = ratio - minCoverageRatioBps;
  return 10_000 - Math.floor((excess * 10_000) / span);
}

export interface CoverageSimResult {
  prospectiveBps: number;
  seniorBlocked: boolean;
  stress: number;
  wouldEmitStress: boolean;
}

/**
 * Simulate a hypothetical senior deposit (and optional concurrent junior deposit) against current
 * pool TVLs. Senior intake reverts when prospective coverage drops below the floor.
 */
export function simulate(
  juniorTVL: bigint,
  seniorTVL: bigint,
  minCoverageRatioBps: number,
  seniorDeposit: bigint,
  juniorDeposit: bigint
): CoverageSimResult {
  const newJunior = juniorTVL + juniorDeposit;
  const prospectiveBps = prospectiveRatioBps(newJunior, seniorTVL, seniorDeposit);
  const stress = stressLevel(prospectiveBps, minCoverageRatioBps);
  return {
    prospectiveBps,
    seniorBlocked: seniorDeposit > 0n && prospectiveBps < minCoverageRatioBps,
    stress,
    wouldEmitStress: stress > STRESS_EMIT_THRESHOLD,
  };
}
