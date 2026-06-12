/**
 * Hand-off between the deposit flow (#deposit) and the dashboard (#app).
 *
 * On a successful zap deposit, DepositPanel stashes the tx + a pre-deposit pool snapshot in
 * sessionStorage, then routes the user to #app where DepositSuccessBanner reads it back and shows
 * the before/after coverage + senior-TVL delta. sessionStorage (not localStorage) so it clears with
 * the tab and never becomes stale clutter across sessions (spec §5.2).
 */

const KEY = "stratum:lastDeposit";

export interface DepositStash {
  txHash: `0x${string}`;
  positionId?: `0x${string}`;
  /** 0 = senior (stLP), 1 = junior (jtLP). */
  tranche: 0 | 1;
  poolId: string;
  /** ms epoch when the deposit confirmed. */
  ts: number;
  /** Coverage ratio (bps) read just before the deposit, if the lens was available. */
  coverageBeforeBps?: number;
  /** Senior TVL (raw 18-dec bigint as string) read just before the deposit. */
  seniorTVLBefore?: string;
  /** Position key inputs, so the positions panel can offer a pre-filled withdraw deep link. */
  userSalt?: string;
  tickLower?: number;
  tickUpper?: number;
}

export function setDepositStash(s: DepositStash): void {
  try {
    sessionStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    /* storage disabled (private mode / SSR): banner just won't show, no crash. */
  }
}

export function readDepositStash(): DepositStash | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return null;
    return JSON.parse(raw) as DepositStash;
  } catch {
    return null;
  }
}

export function clearDepositStash(): void {
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    /* no-op */
  }
}
