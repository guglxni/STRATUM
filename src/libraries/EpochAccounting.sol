// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title EpochAccounting
/// @notice Epoch accumulator, senior obligation, and linear vesting (FR-07, FR-13, INV-06).
library EpochAccounting {
    uint256 public constant YEAR_SECONDS = 365 days;

    /// @notice Senior obligation for one epoch: seniorTVL * apyBps / 10000 * epochSeconds / year.
    function seniorObligationForEpoch(uint256 seniorTVL, uint256 targetAPYBps, uint32 epochSeconds)
        internal
        pure
        returns (uint256)
    {
        return seniorTVL * targetAPYBps * epochSeconds / (10_000 * YEAR_SECONDS);
    }

    /// @notice Linear vesting fraction elapsed in the epoch (0..1e18).
    function vestedFraction(uint32 epochSeconds, uint32 elapsed) internal pure returns (uint256) {
        if (epochSeconds == 0) return 1e18;
        if (elapsed >= epochSeconds) return 1e18;
        return uint256(elapsed) * 1e18 / epochSeconds;
    }

    /// @notice Vested amount from a total accrual.
    function vestedAmount(uint256 total, uint256 vestedFrac1e18) internal pure returns (uint256) {
        return total * vestedFrac1e18 / 1e18;
    }

    /// @notice Cumulative linearly-vested amount of a total accrual, anchored to a position's age (FR-07).
    /// @dev Deterministic (NFR-02). Returns the FULL vested-to-date amount (not an increment), so callers
    ///      release only `result - alreadyReleased`. Monotone non-decreasing in `ageSeconds`; reaches
    ///      `total` once `ageSeconds >= smoothingSeconds`. mulDiv-safe for large totals (R-H3 spirit).
    /// @param total Total accrued earnings to vest over the window.
    /// @param ageSeconds Seconds since the position's accrual start (entry).
    /// @param smoothingSeconds Vesting window length (pool.smoothingEpochSeconds).
    /// @return vested Cumulative vested amount to date.
    function vestedToDate(uint256 total, uint256 ageSeconds, uint32 smoothingSeconds)
        internal
        pure
        returns (uint256 vested)
    {
        if (smoothingSeconds == 0 || ageSeconds >= smoothingSeconds) return total;
        return FullMath.mulDiv(total, ageSeconds, uint256(smoothingSeconds));
    }

    /// @notice Surplus after funding senior obligation from accumulated fees (INV-04).
    function epochSurplus(uint256 accumulated, uint256 seniorObligation, uint256 seniorFunded)
        internal
        pure
        returns (uint256 surplus, uint256 shortfall)
    {
        if (seniorFunded >= seniorObligation) {
            surplus = accumulated > seniorObligation ? accumulated - seniorObligation : 0;
            shortfall = 0;
        } else {
            shortfall = seniorObligation - seniorFunded;
            surplus = 0;
        }
    }
}
