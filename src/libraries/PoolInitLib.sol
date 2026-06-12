// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

import { PoolTrancheState, PoolInitParams, TrancheType } from "../StratumTypes.sol";
import { StratumErrors } from "../StratumErrors.sol";
import { TrancheToken } from "../TrancheToken.sol";
import { EpochAccounting } from "./EpochAccounting.sol";

/// @title PoolInitLib
/// @notice Pool initialization: parameter validation, tranche receipt-token deployment, and the
///         initial `PoolTrancheState` write, executed in the hook's storage context.
/// @dev External library by design (EIP-170): the `new TrancheToken` creation bytecode is embedded
///      in whichever contract performs the deployment. Hosting it here keeps ~4 KB of creation
///      code out of the hook's runtime, which must stay under the deployed-size limit. The library
///      runs via delegatecall, so the tokens are deployed FROM the hook's address context and the
///      state write lands in the hook's storage, identical to the previous inline implementation.
library PoolInitLib {
    /// @notice Validate `params` and initialize `poolStates[id]`, deploying the stLP/jtLP tokens.
    /// @dev Invariants established here: fee band ordering (min <= base <= max), protocol fee cap,
    ///      coverage band ordering (floor <= trigger <= target), and a non-zero coverage floor.
    ///      All pool parameters are set HERE and only here (golden rule 5: no magic numbers later).
    /// @param poolStates The hook's pool-state mapping (storage).
    /// @param id Pool being initialized.
    /// @param params Creator-staged parameters from `preparePool`.
    /// @param hook The hook address, set as the mint/burn authority on both receipt tokens.
    function initializePool(
        mapping(PoolId => PoolTrancheState) storage poolStates,
        PoolId id,
        PoolInitParams memory params,
        address hook
    ) external {
        if (params.minFeeBps > params.baseFeeBps || params.baseFeeBps > params.maxFeeBps) {
            revert StratumErrors.FeeBoundsInvalid();
        }
        if (params.minCoverageRatioBps == 0 || params.maxSeniorILExposureBps > 10_000) {
            revert StratumErrors.FeeBoundsInvalid();
        }
        if (params.protocolFeeBps > 3000) revert StratumErrors.FeeBoundsInvalid();
        // Graduated coverage band (P1): floor <= trigger <= target. Equal-to-floor disables the band.
        if (
            params.coverageTriggerBps < params.minCoverageRatioBps
                || params.coverageTargetBps < params.coverageTriggerBps
        ) {
            revert StratumErrors.CoverageBandInvalid();
        }

        TrancheToken senior = new TrancheToken("Stratum Senior LP", "stLP", TrancheType.SENIOR, hook);
        TrancheToken junior = new TrancheToken("Stratum Junior LP", "jtLP", TrancheType.JUNIOR, hook);

        poolStates[id] = PoolTrancheState({
            seniorTVL: 0,
            juniorTVL: 0,
            juniorReserve: 0,
            targetAPYBps: params.targetAPYBps,
            minCoverageRatioBps: params.minCoverageRatioBps,
            maxSeniorILExposureBps: params.maxSeniorILExposureBps,
            smoothingEpochSeconds: params.smoothingEpochSeconds,
            currentEpoch: 0,
            epochAccumulatedFees: 0,
            epochSeniorObligation: EpochAccounting.seniorObligationForEpoch(
                0, params.targetAPYBps, params.smoothingEpochSeconds
            ),
            epochSeniorFunded: 0,
            volatilityEWMA: 0,
            baseFeeBps: params.baseFeeBps,
            minFeeBps: params.minFeeBps,
            maxFeeBps: params.maxFeeBps,
            protocolFeeBps: params.protocolFeeBps,
            poolCumulativeIL: 0,
            peripheralRegistry: params.peripheralRegistry,
            seniorToken: address(senior),
            juniorToken: address(junior),
            initialized: true,
            epochStartTimestamp: block.timestamp,
            seniorFeePerShareX128: 0,
            juniorFeePerShareX128: 0,
            coverageTriggerBps: params.coverageTriggerBps,
            coverageTargetBps: params.coverageTargetBps
        });
    }
}
