/**
 * Typed query strings for the STRATUM subgraph (Phase D).
 * Field names mirror subgraph/schema.graphql exactly; do not invent fields
 * (FRONTEND_UPGRADE_INSTRUCTIONS 7.3 agent rule).
 */

export const POOL_EPOCHS = `
  query PoolEpochs($poolId: String!, $first: Int!) {
    epoches(where: { pool: $poolId }, orderBy: epoch, orderDirection: desc, first: $first) {
      id
      epoch
      seniorFunded
      juniorSurplus
      juniorReserve
      closedAt
    }
  }
`;

export interface EpochRow {
  id: string;
  epoch: string;
  seniorFunded: string;
  juniorSurplus: string;
  juniorReserve: string;
  closedAt: string;
}

export const POOL_SWAPS = `
  query PoolSwaps($poolId: String!, $first: Int!) {
    swaps(where: { pool: $poolId }, orderBy: timestamp, orderDirection: desc, first: $first) {
      id
      epoch
      feeAmount
      volatilityEWMA
      coverageRatioBps
      timestamp
      txHash
    }
  }
`;

export interface SwapRow {
  id: string;
  epoch: string;
  feeAmount: string;
  volatilityEWMA: string;
  coverageRatioBps: number;
  timestamp: string;
  txHash: string;
}

export const COVERAGE_EVENTS = `
  query CoverageEvents($poolId: String!, $first: Int!) {
    coverageStressEvents(
      where: { pool: $poolId }
      orderBy: timestamp
      orderDirection: desc
      first: $first
    ) {
      id
      ratioBps
      stressLevel
      timestamp
    }
  }
`;

export interface CoverageEventRow {
  id: string;
  ratioBps: number;
  stressLevel: number;
  timestamp: string;
}
