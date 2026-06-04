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
        if (ratioBps_ >= minCoverageRatioBps * 2) return 0;
        if (ratioBps_ <= minCoverageRatioBps) return 10_000;
        uint256 span = minCoverageRatioBps;
        uint256 excess = ratioBps_ - minCoverageRatioBps;
        return uint16(10_000 - (excess * 10_000 / span));
    }
}
