/**
 * Event ABIs for the hook's history stream, used to read epoch/swap/stress history directly from the
 * chain via viem `getLogs` - the zero-setup fallback when no subgraph URL is configured. Signatures
 * mirror StratumHook exactly (verified against the full forge-generated ABI).
 */

import { parseAbiItem } from "viem";

export const EVENT_EPOCH_CLOSED = parseAbiItem(
  "event EpochClosed(bytes32 indexed poolId, uint64 indexed epoch, uint256 seniorFunded, uint256 juniorSurplus)"
);

export const EVENT_SWAP_ACCOUNTED = parseAbiItem(
  "event SwapAccounted(bytes32 indexed poolId, uint64 indexed epoch, uint256 feeAmount, uint256 volatilityEWMA, uint16 coverageRatioBps)"
);

export const EVENT_COVERAGE_STRESS = parseAbiItem(
  "event CoverageStress(bytes32 indexed poolId, uint16 ratioBps, uint16 stressLevel)"
);
