// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Waterfall
/// @notice Senior-first fee split and dynamic swap fee (FR-04, FR-05, INV-04).
library Waterfall {
    struct Split {
        uint256 seniorPortion;
        uint256 juniorPortion;
        uint256 protocolPortion;
    }

    /// @notice Clamp dynamic fee between bounds; raise fee under stress/volatility.
    function dynamicFeeBps(
        uint16 baseFeeBps,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint256 volatilityEWMA,
        uint16 stressLevel
    ) internal pure returns (uint16) {
        uint256 volBump = volatilityEWMA / 1e14;
        if (volBump > 500) volBump = 500;
        uint256 stressBump = (uint256(stressLevel) * uint256(maxFeeBps - baseFeeBps)) / 20_000;
        uint256 fee = uint256(baseFeeBps) + volBump + stressBump;
        if (fee < minFeeBps) fee = minFeeBps;
        if (fee > maxFeeBps) fee = maxFeeBps;
        return uint16(fee);
    }

    /// @notice Split a fee amount into senior obligation funding, junior surplus, and protocol fee.
    /// @dev seniorBps + juniorBps + protocolBps must equal 10000 at the pool level.
    function splitFee(uint256 feeAmount, uint16 protocolFeeBps, uint256 volatilityEWMA, uint16 stressLevel)
        internal
        pure
        returns (Split memory s)
    {
        uint256 seniorWeight = 4000 + (uint256(stressLevel) * 3000) / 10_000;
        uint256 protocolWeight = protocolFeeBps;
        // Clamp so senior + protocol never exceeds 100%, guaranteeing a non-negative junior remainder.
        if (seniorWeight + protocolWeight > 10_000) {
            seniorWeight = 10_000 - protocolWeight;
        }

        s.seniorPortion = feeAmount * seniorWeight / 10_000;
        s.protocolPortion = feeAmount * protocolWeight / 10_000;
        s.juniorPortion = feeAmount - s.seniorPortion - s.protocolPortion;

        // Under high volatility, tilt an extra slice from junior to senior funding.
        if (volatilityEWMA > 1e16 && s.juniorPortion > 0) {
            uint256 shift = s.juniorPortion / 10;
            s.juniorPortion -= shift;
            s.seniorPortion += shift;
        }
    }
}
