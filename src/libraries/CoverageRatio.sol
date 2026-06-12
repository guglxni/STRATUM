// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CoverageRatio
/// @notice Junior/senior coverage floor and stress scalar (FR-11, FR-12, INV-01).
library CoverageRatio {
    error CoverageRatioBelowFloor(uint16 ratioBps, uint16 minBps);

    /// @notice Coverage ratio in basis points: juniorTVL * 10000 / seniorTVL.
    /// @dev Returns type(uint16).max when seniorTVL is zero (infinite coverage).
    function ratioBps(uint256 juniorTVL, uint256 seniorTVL) internal pure returns (uint16) {
        if (seniorTVL == 0) return type(uint16).max;
        uint256 r = juniorTVL * 10_000 / seniorTVL;
        if (r > type(uint16).max) return type(uint16).max;
        return uint16(r);
    }

    /// @notice Prospective ratio after a senior deposit of `depositValue`.
    function prospectiveRatioBps(uint256 juniorTVL, uint256 seniorTVL, uint256 depositValue)
        internal
        pure
        returns (uint16)
    {
        return ratioBps(juniorTVL, seniorTVL + depositValue);
    }

    /// @notice Reverts if prospective coverage is below the configured floor.
    function enforceOnSeniorIntake(
        uint256 juniorTVL,
        uint256 seniorTVL,
        uint256 depositValue,
        uint16 minCoverageRatioBps
    ) internal pure {
        uint16 prospective = prospectiveRatioBps(juniorTVL, seniorTVL, depositValue);
        if (prospective < minCoverageRatioBps) {
            revert CoverageRatioBelowFloor(prospective, minCoverageRatioBps);
        }
    }

    /// @notice Stress level 0..10000; higher means more stress (closer to floor).
    function stressLevel(uint16 ratioBps_, uint16 minCoverageRatioBps) internal pure returns (uint16) {
        // M-09: widen to uint256 before doubling. `minCoverageRatioBps * 2` in uint16 overflows for any
        // floor >= 32768 bps (a valid conservative config), which would Panic-revert on every swap/add and
        // brick the pool from its first deposit. The comparison itself is unaffected for small floors.
        if (uint256(ratioBps_) >= uint256(minCoverageRatioBps) * 2) return 0;
        if (ratioBps_ <= minCoverageRatioBps) return 10_000;
        uint256 span = minCoverageRatioBps;
        uint256 excess = ratioBps_ - minCoverageRatioBps;
        return uint16(10_000 - (excess * 10_000 / span));
    }

    /// @notice Continuous remediation intensity in bps (0..10000) as coverage decays from `triggerBps`
    ///         toward `floorBps`. This is the "slope, not cliff" control variable (P1 graduated coverage
    ///         defense): an opt-in CoverageDefender peripheral scales its rebalance ask by this value so
    ///         intervention ramps up smoothly instead of all firing at a single hard threshold.
    /// @dev Returns 0 in the healthy band (ratio >= trigger), 10000 at or below the floor, and a linear
    ///      interpolation in between. A degenerate band (trigger <= floor) collapses to a binary response at
    ///      the floor, preserving "feature off" semantics when trigger == floor.
    /// @param ratioBps_ Current coverage ratio in bps.
    /// @param triggerBps Early-warning threshold; remediation begins below this.
    /// @param floorBps Hard coverage floor (minCoverageRatioBps); maximum intensity at or below it.
    /// @return scaleBps Remediation intensity, 0..10000.
    function remediationScaleBps(uint16 ratioBps_, uint16 triggerBps, uint16 floorBps)
        internal
        pure
        returns (uint16 scaleBps)
    {
        if (triggerBps <= floorBps) {
            // Degenerate band: no early-warning slope, only a binary response at the floor.
            return ratioBps_ <= floorBps ? 10_000 : 0;
        }
        if (ratioBps_ >= triggerBps) return 0;
        if (ratioBps_ <= floorBps) return 10_000;
        uint256 span = uint256(triggerBps) - floorBps;
        uint256 belowTrigger = uint256(triggerBps) - ratioBps_;
        return uint16(belowTrigger * 10_000 / span);
    }
}
