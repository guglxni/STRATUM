// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LVRProceedsValidator
/// @notice Optional sanity bound for LVR-auction proceeds (P5/FR-28). Given a caller-supplied asset price, it
///         caps the USD proceeds a claim may assert at `price * tokenAmount * maxLvrFactorBps / 10000`, so a
///         misreporting or compromised AVS operator cannot credit the senior reserve with fabricated yield far
///         above what the captured LVR could rationally be.
/// @dev Pure library (house style: small, isolated, testable). It is oracle-agnostic and a VALIDATION bound
///      only: the price is passed in by the caller, and the result never enters IL, coverage, or settlement math
///      (golden rule 2). Wired into `LVRAuctionReceiver.receiveYield` (via `setProceedsBound`), which supplies an
///      independent Chainlink USD price and the pool's on-chain TVL as the notional, and reverts the routing when
///      a claim exceeds the bound. This library only answers "is it within bound".
library LVRProceedsValidator {
    /// @dev USD prices are expected in 8-decimal fixed point (1e8 == 1.0 USD), the standard Chainlink USD-feed
    ///      decimals. If the caller's feed uses a different scale, normalise to 8 decimals before calling.
    uint256 internal constant USD_PRICE_SCALE = 1e8;

    /// @notice Maximum rational USD proceeds for a captured token amount at a given asset price.
    /// @dev `price8dp` and `tokenAmount` are both fixed-point; the result is USD scaled to `tokenAmount`'s units.
    ///      Uses unchecked-free 0.8 arithmetic (reverts on overflow, which for a sane price/amount/factor is
    ///      unreachable; a revert is the safe failure here).
    /// @param price8dp Asset price, 8-decimal fixed point.
    /// @param tokenAmount Amount of the captured token (same decimals the caller denominates proceeds in).
    /// @param maxLvrFactorBps Upper bound on capturable LVR as a fraction of notional, in bps.
    /// @return maxProceeds Maximum USD-denominated proceeds the claim may rationally assert.
    function maxRationalProceeds(uint256 price8dp, uint256 tokenAmount, uint16 maxLvrFactorBps)
        internal
        pure
        returns (uint256 maxProceeds)
    {
        // notionalUSD = price * amount / 1e8; bound = notionalUSD * factorBps / 10000.
        uint256 notionalUSD = price8dp * tokenAmount / USD_PRICE_SCALE;
        maxProceeds = notionalUSD * uint256(maxLvrFactorBps) / 10_000;
    }

    /// @notice True if `claimedProceedsUSD` does not exceed the rational bound for the captured amount.
    /// @dev A zero price (adapter never pushed, or stale-read returned 0) yields a zero bound, so any positive
    ///      claim is reported out-of-bound: the caller should treat an unconfigured/stale feed as "cannot
    ///      validate" and fall back to its own gating (here, the receiver's attestation quorum). This fail-safe
    ///      keeps the bound from silently passing everything when the price is unavailable.
    function isWithinBound(uint256 price8dp, uint256 tokenAmount, uint256 claimedProceedsUSD, uint16 maxLvrFactorBps)
        internal
        pure
        returns (bool)
    {
        return claimedProceedsUSD <= maxRationalProceeds(price8dp, tokenAmount, maxLvrFactorBps);
    }
}
