// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title StratumRateLibrary
/// @notice Chainlink-benchmarked senior target APY with a spread floor (FR-25, DESIGN section 2).
///
/// @dev This library computes the effective `targetAPYBps` for the senior tranche as:
///
///          effectiveAPYBps = max(configuredAPYBps, benchmarkRateBps + spreadBps)
///
///      where `benchmarkRateBps` is read from a Chainlink AggregatorV3Interface price feed that exposes a
///      reference rate (e.g. SOFR, ETH staking yield, or a comparable DeFi benchmark) in basis points.
///
///      Graceful fallback: if the feed address is `address(0)`, or if the Chainlink call reverts, or if the
///      returned answer is non-positive (stale answer == 0 or invalid), the library silently falls back to
///      `configuredAPYBps`. This ensures the core never relies on an external data source for its IL
///      accounting paths (golden rule 2) and the core-only CI profile (NFR-01) is never broken by a missing
///      feed.
///
///      The library is pure/view, has no storage, and can be used both in the hook and in off-chain scripts.
///      The caller (hook's `closeEpoch` or an admin update path) is responsible for writing the returned bps
///      back to `PoolTrancheState.targetAPYBps`.
///
///      Scale assumption: the Chainlink feed is expected to return the rate in 8-decimal fixed point (the
///      standard Chainlink decimals for yield feeds), i.e. 1e8 == 100%. One basis point is 1e4.
///      Formula: `benchmarkRateBps = uint256(answer) * 10_000 / 1e8`.
///      If the feed uses a different decimal count, pass the `feedDecimals` parameter.
///
///      IMPORTANT: this library MUST NOT be called from IL accounting paths. It is intended only for the
///      `targetAPYBps` parameter update in `PoolTrancheState`, never inside `_settleSenior`, `_settleJunior`,
///      or any math that computes per-position payouts.
/// @notice Minimal AggregatorV3 interface; only `latestRoundData` and `decimals` are needed.
/// @dev Declared at file scope: interfaces nested inside libraries are not valid in Solidity 0.8.x.
interface AggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}

library StratumRateLibrary {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Maximum age (in seconds) of a Chainlink round before it is considered stale.
    /// @dev 25 hours allows for one missed heartbeat on daily-update feeds.
    uint256 public constant MAX_FEED_AGE_SECONDS = 25 hours;

    /// @notice Upper bound on the computed benchmark rate (in bps) to prevent runaway values from bad feeds.
    uint256 public constant MAX_BENCHMARK_BPS = 50_000; // 500% APY

    // -------------------------------------------------------------------------
    // Core computation
    // -------------------------------------------------------------------------

    /// @notice Compute the effective senior target APY in basis points (default bounds).
    /// @dev Backward-compatible overload: uses `MAX_BENCHMARK_BPS` as the sane-rate ceiling and
    ///      `MAX_FEED_AGE_SECONDS` as the staleness window. Prefer the 5-arg form for per-pool bounds.
    function effectiveTargetAPYBps(uint256 configuredAPYBps, uint256 spreadBps, address feedAddress)
        internal
        view
        returns (uint256 effectiveAPYBps)
    {
        return effectiveTargetAPYBps(configuredAPYBps, spreadBps, feedAddress, MAX_BENCHMARK_BPS, MAX_FEED_AGE_SECONDS);
    }

    /// @notice Compute the effective senior target APY in basis points with per-pool bounds.
    /// @dev Falls back to `configuredAPYBps` when the feed is unavailable, stale, or returns a raw benchmark
    ///      ABOVE `maxBenchmarkBps`. The last case is the key hardening (finding 1): a benchmark far above any
    ///      plausible rate almost always means a *price* feed was wired where a *rate* feed was expected (e.g. an
    ///      ETH/USD feed reads as millions of bps). Rather than silently clamp such a misconfiguration to the
    ///      hard cap (which pins the senior target at 500%), we reject it and fall back to the configured floor.
    ///      Does NOT revert under any oracle failure condition (graceful fallback, golden rule 2).
    ///
    /// @param configuredAPYBps  The pool's configured floor APY (bps). Always the minimum.
    /// @param spreadBps         Spread added on top of the benchmark rate (bps).
    /// @param feedAddress       Chainlink AggregatorV3 address. Pass `address(0)` to use configured only.
    /// @param maxBenchmarkBps   Sane ceiling on the RAW benchmark (before spread). A raw value above this is
    ///                          treated as a misconfigured feed and ignored. Pass 0 to use `MAX_BENCHMARK_BPS`.
    /// @param maxFeedAgeSeconds Per-feed staleness window (finding 2): a round older than this is rejected. Set
    ///                          to the specific feed's heartbeat + a grace margin. Pass 0 to use the 25h default.
    /// @return effectiveAPYBps  The effective APY in basis points: max(configuredAPYBps, benchmarkBps + spreadBps).
    function effectiveTargetAPYBps(
        uint256 configuredAPYBps,
        uint256 spreadBps,
        address feedAddress,
        uint256 maxBenchmarkBps,
        uint256 maxFeedAgeSeconds
    ) internal view returns (uint256 effectiveAPYBps) {
        if (feedAddress == address(0)) {
            return configuredAPYBps;
        }

        uint256 ceiling = maxBenchmarkBps == 0 ? MAX_BENCHMARK_BPS : maxBenchmarkBps;
        uint256 age = maxFeedAgeSeconds == 0 ? MAX_FEED_AGE_SECONDS : maxFeedAgeSeconds;

        uint256 benchmarkBps = _safeFetchBenchmarkBps(feedAddress, age);
        if (benchmarkBps == 0) {
            // Feed unavailable or stale: fall back.
            return configuredAPYBps;
        }
        if (benchmarkBps > ceiling) {
            // Out-of-band raw benchmark: almost certainly a price feed wired as a rate feed. Fall back to the
            // floor instead of clamping to the hard cap (finding 1).
            return configuredAPYBps;
        }

        uint256 withSpread = benchmarkBps + spreadBps;
        if (withSpread > MAX_BENCHMARK_BPS) withSpread = MAX_BENCHMARK_BPS; // hard backstop

        return withSpread > configuredAPYBps ? withSpread : configuredAPYBps;
    }

    /// @notice Fetch the benchmark rate in bps from a Chainlink feed, returning 0 on any failure.
    /// @dev Wraps `latestRoundData` in a try/catch. Validates: positive answer, non-stale timestamp,
    ///      round completeness. Returns 0 on any failure so the caller can detect and fall back.
    ///
    /// @param feedAddress       Chainlink AggregatorV3 address.
    /// @param maxFeedAgeSeconds Maximum age of the latest round before it is considered stale.
    /// @return benchmarkBps Rate in basis points, or 0 if the feed is unavailable/stale.
    function _safeFetchBenchmarkBps(address feedAddress, uint256 maxFeedAgeSeconds)
        internal
        view
        returns (uint256 benchmarkBps)
    {
        // Guard: skip the call entirely for non-contract addresses. `extcodesize` returns 0 for EOAs and
        // undeployed addresses. The Solidity `try/catch` alone does not catch the low-level revert that
        // Cancun EVM emits for calls to non-contract addresses when the return type is non-void.
        uint256 codeSize;
        assembly ("memory-safe") {
            codeSize := extcodesize(feedAddress)
        }
        if (codeSize == 0) return 0;

        try AggregatorV3(feedAddress).decimals() returns (uint8 dec) {
            // Reject out-of-range decimals BEFORE exponentiating: `10 ** dec` overflows uint256 for dec >= 78 and
            // would revert with an arithmetic panic INSIDE this try body, which `catch` does not intercept (catch
            // only traps the external call's revert), bricking the caller. No real feed exceeds ~30 decimals.
            if (dec > 36) return 0;
            try AggregatorV3(feedAddress).latestRoundData() returns (
                uint80 roundId,
                int256 answer,
                uint256, /* startedAt */
                uint256 updatedAt,
                uint80 answeredInRound
            ) {
                // Validate round completeness.
                if (answeredInRound < roundId) return 0;
                // Validate non-stale data against the caller-supplied (per-feed) window. A future `updatedAt`
                // (cannot happen for a real same-chain feed) is treated as invalid, not as "fresh".
                if (updatedAt > block.timestamp) return 0;
                if (block.timestamp > updatedAt + maxFeedAgeSeconds) return 0;
                // Validate non-negative, non-zero answer.
                if (answer <= 0) return 0;

                // Convert from feed's fixed-point to basis points.
                // benchmarkRateBps = answer * 10_000 / 10^dec
                uint256 scale = 10 ** uint256(dec);
                benchmarkBps = uint256(answer) * 10_000 / scale;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    // -------------------------------------------------------------------------
    // Convenience: update a pool's targetAPYBps in-place
    // -------------------------------------------------------------------------

    /// @notice Compute the effective APY and compare against an existing `targetAPYBps`, returning the
    ///         updated value. Useful in a single-expression hook update:
    ///         `pool.targetAPYBps = StratumRateLibrary.updatedTargetAPYBps(pool.targetAPYBps, spreadBps, feed);`
    ///
    /// @param currentAPYBps  The pool's current `targetAPYBps` (acts as the configured floor).
    /// @param spreadBps      Spread over the benchmark.
    /// @param feedAddress    Chainlink feed. `address(0)` returns `currentAPYBps` unchanged.
    /// @return newAPYBps     The potentially-raised targetAPYBps.
    function updatedTargetAPYBps(uint256 currentAPYBps, uint256 spreadBps, address feedAddress)
        internal
        view
        returns (uint256 newAPYBps)
    {
        return effectiveTargetAPYBps(currentAPYBps, spreadBps, feedAddress);
    }

    /// @notice Per-pool-bounded variant of `updatedTargetAPYBps` (see the 5-arg `effectiveTargetAPYBps`).
    function updatedTargetAPYBps(
        uint256 currentAPYBps,
        uint256 spreadBps,
        address feedAddress,
        uint256 maxBenchmarkBps,
        uint256 maxFeedAgeSeconds
    ) internal view returns (uint256 newAPYBps) {
        return effectiveTargetAPYBps(currentAPYBps, spreadBps, feedAddress, maxBenchmarkBps, maxFeedAgeSeconds);
    }
}
