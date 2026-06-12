// SPDX-License-Identifier: MIT
//! ML forward-volatility model.
//!
//! Replaces the hook's simple reactive EWMA (`ILMath.updateVolatilityEWMA`) with a model that
//! forecasts the *next-step* volatility regime so the dynamic fee can be set proactively
//! (ARCHITECTURE.md section 8, TECHNICAL_DESIGN.md "Stylus engine"). Output is a predicted volatility EWMA in
//! the exact same fixed-point scale as the on-chain `PoolTrancheState.volatilityEWMA`.
//!
//! ## Fixed-point scale (must match the hook)
//!
//! On-chain, `instant = delta(sqrtPrice) / prevSqrtPrice` scaled by `1e18`, then
//! `EWMA = (prevEWMA * 9 + instant) / 10`. So `1e18 == 1.0` (a 100% instantaneous sqrt-price move);
//! a 1% move is `1e16`. We keep the identical WAD scale: every value in this module that represents
//! a volatility ratio is in WAD ([`VOL_EWMA_WAD`]).
//!
//! ## Model
//!
//! Two components combined:
//!
//! 1. **EWMA baseline** - the same 0.9/0.1 smoothing the hook uses, so with no predictive signal the
//!    model degrades gracefully to the on-chain behaviour (the peripheral-down fallback in section
//!    10.3 of ARCHITECTURE).
//! 2. **GARCH(1,1)-lite forward term** - an online variance recursion
//!    `sigma2_next = omega + alpha * r^2 + beta * sigma2`, where `r` is the latest sqrt-price return
//!    (in WAD). This captures volatility clustering: a burst of large returns raises the forecast for
//!    the next step even before the EWMA fully catches up. Parameters are learned-free (fixed,
//!    documented) so the model is deterministic and needs no training data on-chain; `omega/alpha/beta`
//!    are the standard near-unit-root choice that mean-reverts slowly.
//!
//! The forecast is `predicted = max(ewma_baseline, garch_forecast)` then clamped to [`MAX_VOL_EWMA`]
//! so a runaway recursion can never hand the consumer a fee multiplier that breaks the hook.

/// WAD scale for volatility values: `1e18 == 1.0`. Identical to the hook's `volatilityEWMA` scale.
pub const VOL_EWMA_WAD: u128 = 1_000_000_000_000_000_000;

/// Hard cap on any predicted EWMA, WAD. `2e18 == 200%` instantaneous-equivalent volatility. The
/// hook's fee curve saturates well below this, but the cap guarantees a bounded, non-panicking
/// output even under adversarial inputs. A runaway GARCH recursion is clamped here.
pub const MAX_VOL_EWMA: u128 = 2 * VOL_EWMA_WAD;

/// EWMA smoothing numerator/denominator for the baseline: new = (old*9 + instant)/10. Matches
/// `ILMath.updateVolatilityEWMA`.
const EWMA_OLD_WEIGHT: u128 = 9;
const EWMA_DENOM: u128 = 10;

// GARCH(1,1)-lite parameters, all in WAD. Chosen to be persistent (alpha + beta < 1 so the variance
// process is stationary and mean-reverts) with a small constant floor omega.
//   omega = 1e14  (0.0001 in WAD): a tiny baseline variance floor so the forecast never collapses to 0.
//   alpha = 1e17  (0.1):           weight on the latest squared return (the "shock" term).
//   beta  = 8.5e17 (0.85):         weight on the previous variance (the "persistence" term).
// alpha + beta = 0.95 < 1 -> stationary. These mirror typical equity-vol GARCH fits.
const GARCH_OMEGA: u128 = 100_000_000_000_000; // 1e14
const GARCH_ALPHA: u128 = 100_000_000_000_000_000; // 1e17
const GARCH_BETA: u128 = 850_000_000_000_000_000; // 8.5e17

/// A volatility forecast bundle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VolForecast {
    /// Predicted next-step volatility EWMA, WAD. This is what populates
    /// `MatchResult.predictedVolatilityEWMA[i]` and is consumed by `StylusShim.getVolatilityOverride`.
    pub predicted_ewma: u128,
    /// The EWMA baseline component (for diagnostics / tests), WAD.
    pub ewma_baseline: u128,
    /// The GARCH forward variance forecast as a volatility level, WAD.
    pub garch_forecast: u128,
}

/// Online forward-volatility model for a single pool. Update it with each new sqrt-price observation;
/// read [`VolModel::forecast`] for the next-step prediction.
///
/// State is tiny (three u128s) and the update is O(1), so one instance per pool is cheap to keep in
/// Stylus storage. Deterministic: same observation sequence -> same forecast.
#[derive(Clone, Copy, Debug)]
pub struct VolModel {
    /// Current EWMA baseline, WAD.
    ewma: u128,
    /// Current GARCH variance estimate `sigma2`, in WAD-of-variance (a squared WAD ratio kept in WAD
    /// scale via the `wad_sq`/`wad_sqrt` helpers).
    sigma2: u128,
    /// Whether at least one observation has been seen (seeds EWMA on the first instant, like the hook).
    seeded: bool,
}

impl Default for VolModel {
    fn default() -> Self {
        Self::new()
    }
}

impl VolModel {
    /// Fresh model: no history. The first `update` seeds the EWMA to the first instant value,
    /// matching the hook's `prevEWMA == 0 -> return instant` behaviour.
    pub fn new() -> Self {
        Self { ewma: 0, sigma2: GARCH_OMEGA, seeded: false }
    }

    /// Construct from a known on-chain EWMA so the model can warm-start from the hook's current state
    /// instead of cold. `ewma` is WAD.
    pub fn from_ewma(ewma: u128) -> Self {
        Self { ewma, sigma2: GARCH_OMEGA.max(wad_sq(ewma)), seeded: ewma != 0 }
    }

    /// (Host-side only) Warm-start the model from a slice of WAD-scaled instantaneous volatility
    /// observations sourced from real price history. This is the intended entry point for the
    /// off-chain trainer: it feeds a series of historical returns into the model before the
    /// resulting state is checkpointed on-chain via `StylusShim.setVolatilityOverride`. The price
    /// history is supplied by the caller from any source (a Chainlink price feed read over a range
    /// of rounds, an indexer, or a CSV); this constructor only consumes the derived instants.
    ///
    /// ## Typical caller flow (off-chain trainer)
    ///
    /// ```rust,ignore
    /// use stratum_stylus::VolModel;
    ///
    /// // `instants` is a slice of WAD-scaled instantaneous volatility observations derived from
    /// // a historical price series (e.g. successive Chainlink rounds turned into log-returns).
    /// let model = VolModel::warm_start_from_instants(&instants);
    /// // model.forecast().predicted_ewma is the initial volatilityEWMA override.
    /// ```
    ///
    /// On-chain inference uses the stateless `update` method; this constructor is never called
    /// from the Stylus entrypoint. The `#[cfg(not(target_arch = "wasm32"))]` gate enforces that:
    /// if this function were somehow referenced from the entrypoint the wasm32 build would fail
    /// at compile time.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn warm_start_from_instants(instants: &[u128]) -> Self {
        let mut m = Self::new();
        for &inst in instants {
            m.update(inst);
        }
        m
    }

    /// Feed one instantaneous volatility observation `instant` (WAD), i.e. the same
    /// `delta(sqrtPrice)/prevSqrtPrice * 1e18` the hook computes. Updates both the EWMA baseline and
    /// the GARCH variance recursion. Returns the new forecast for convenience.
    ///
    /// The GARCH recursion is `sigma2 = omega + alpha * r^2 + beta * sigma2_prev`, with `r == instant`.
    /// `r^2` is computed in WAD via [`wad_sq`]. The whole thing is saturating so adversarial spikes
    /// cannot overflow.
    pub fn update(&mut self, instant: u128) -> VolForecast {
        let instant = instant.min(MAX_VOL_EWMA); // bound the raw input before it feeds the recursion

        // --- EWMA baseline (mirrors ILMath) ---
        if !self.seeded {
            self.ewma = instant;
            self.seeded = true;
        } else {
            self.ewma = self
                .ewma
                .saturating_mul(EWMA_OLD_WEIGHT)
                .saturating_add(instant)
                / EWMA_DENOM;
        }

        // --- GARCH(1,1)-lite variance recursion ---
        let r2 = wad_sq(instant); // latest squared return, WAD
        let alpha_term = wad_mul(GARCH_ALPHA, r2);
        let beta_term = wad_mul(GARCH_BETA, self.sigma2);
        self.sigma2 = GARCH_OMEGA
            .saturating_add(alpha_term)
            .saturating_add(beta_term);

        self.forecast()
    }

    /// Current next-step forecast without feeding a new observation.
    ///
    /// `garch_forecast = sqrt(sigma2)` brings the variance back to a volatility level (WAD). The
    /// returned `predicted_ewma` is `max(ewma_baseline, garch_forecast)` clamped to [`MAX_VOL_EWMA`]:
    /// we take the more conservative (higher) of the smoothed history and the clustering forecast so
    /// the fee leans defensive going into a predicted vol spike, then bound it.
    pub fn forecast(&self) -> VolForecast {
        let garch = wad_sqrt(self.sigma2).min(MAX_VOL_EWMA);
        let baseline = self.ewma.min(MAX_VOL_EWMA);
        let predicted = baseline.max(garch).min(MAX_VOL_EWMA);
        VolForecast {
            predicted_ewma: predicted,
            ewma_baseline: baseline,
            garch_forecast: garch,
        }
    }

    /// The current EWMA baseline (WAD), exposed for tests/diagnostics.
    pub fn ewma(&self) -> u128 {
        self.ewma
    }
}

/// WAD multiply: `floor(a * b / 1e18)`, overflow-safe via the crate's 256-bit mul_div.
#[inline]
fn wad_mul(a: u128, b: u128) -> u128 {
    crate::mul_div(a, b, VOL_EWMA_WAD)
}

/// Square in WAD: `floor(x^2 / 1e18)`. Keeps a WAD ratio in WAD scale after squaring.
#[inline]
fn wad_sq(x: u128) -> u128 {
    wad_mul(x, x)
}

/// Integer square root of a WAD-scaled value, returning a WAD-scaled result.
/// For `y = x^2 / 1e18` (i.e. `wad_sq`), `wad_sqrt(y) == x` up to integer rounding. Implemented as
/// `isqrt(value * 1e18)` so the WAD scale is preserved: sqrt(v * 1e18) where v is already WAD gives
/// a WAD-scaled root. Uses Newton's method on u128 with a u256-safe seed.
#[inline]
fn wad_sqrt(value_wad: u128) -> u128 {
    if value_wad == 0 {
        return 0;
    }
    // We want sqrt(value_wad / 1e18) * 1e18 = sqrt(value_wad * 1e18).
    // Compute n = value_wad * 1e18 as a 256-bit number, then isqrt it.
    let (hi, lo) = mul_full_local(value_wad, VOL_EWMA_WAD);
    isqrt_256(hi, lo)
}

/// 128x128 -> 256 multiply (high, low). Local copy to keep this module self-contained.
#[inline]
fn mul_full_local(a: u128, b: u128) -> (u128, u128) {
    let a_lo = a & 0xFFFF_FFFF_FFFF_FFFF;
    let a_hi = a >> 64;
    let b_lo = b & 0xFFFF_FFFF_FFFF_FFFF;
    let b_hi = b >> 64;

    let ll = a_lo * b_lo;
    let lh = a_lo * b_hi;
    let hl = a_hi * b_lo;
    let hh = a_hi * b_hi;

    let mid = (ll >> 64) + (lh & 0xFFFF_FFFF_FFFF_FFFF) + (hl & 0xFFFF_FFFF_FFFF_FFFF);
    let lo = (ll & 0xFFFF_FFFF_FFFF_FFFF) | (mid << 64);
    let hi = hh + (lh >> 64) + (hl >> 64) + (mid >> 64);
    (hi, lo)
}

/// Integer square root of a 256-bit value (hi, lo), returning a u128. Bit-by-bit (Hacker's Delight
/// style) so it needs no 256-bit division. The result fits in u128 because sqrt of a <256-bit value
/// is <128 bits.
#[inline]
fn isqrt_256(hi: u128, lo: u128) -> u128 {
    if hi == 0 {
        return isqrt_128(lo);
    }
    // Result root has up to 128 bits. We compute it bit by bit from the top.
    let mut root: u128 = 0;
    // The "remainder" tracks value - root^2 conceptually; we use the classic restoring algorithm
    // operating on the 256-bit operand. Bit position of the highest set bit pair.
    // bit starts at the largest power of four <= value.
    let mut bit_pos: u32 = 127; // root bit index
    while bit_pos != u32::MAX {
        let candidate = root | (1u128 << bit_pos);
        // Compare candidate^2 against the 256-bit value.
        let (cand_hi, cand_lo) = mul_full_local(candidate, candidate);
        if cmp_256(cand_hi, cand_lo, hi, lo) != core::cmp::Ordering::Greater {
            root = candidate;
        }
        if bit_pos == 0 {
            break;
        }
        bit_pos -= 1;
    }
    root
}

/// Integer square root of a u128 via bit-by-bit restoring method.
#[inline]
fn isqrt_128(value: u128) -> u128 {
    if value == 0 {
        return 0;
    }
    let mut root: u128 = 0;
    let mut bit_pos: u32 = 63; // sqrt of a 128-bit value is <= 64 bits
    while bit_pos != u32::MAX {
        let candidate = root | (1u128 << bit_pos);
        // candidate^2 may overflow u128 only if candidate > 2^64, which it never is here.
        if let Some(sq) = candidate.checked_mul(candidate) {
            if sq <= value {
                root = candidate;
            }
        }
        if bit_pos == 0 {
            break;
        }
        bit_pos -= 1;
    }
    root
}

/// Compare two 256-bit values (hi, lo).
#[inline]
fn cmp_256(a_hi: u128, a_lo: u128, b_hi: u128, b_lo: u128) -> core::cmp::Ordering {
    match a_hi.cmp(&b_hi) {
        core::cmp::Ordering::Equal => a_lo.cmp(&b_lo),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 1% instantaneous move == 1e16 WAD.
    const ONE_PCT: u128 = 10_000_000_000_000_000; // 1e16
    const FIVE_PCT: u128 = 50_000_000_000_000_000; // 5e16

    #[test]
    fn wad_sqrt_roundtrips_squares() {
        for &x in &[ONE_PCT, FIVE_PCT, VOL_EWMA_WAD, VOL_EWMA_WAD / 3, 7 * ONE_PCT] {
            let sq = wad_sq(x);
            let root = wad_sqrt(sq);
            // Allow tiny integer-rounding slack.
            let diff = if root > x { root - x } else { x - root };
            assert!(diff <= 2, "x={x} root={root} diff={diff}");
        }
    }

    #[test]
    fn fresh_model_seeds_to_first_instant() {
        let mut m = VolModel::new();
        let f = m.update(ONE_PCT);
        // EWMA baseline seeds exactly to the first instant (matches ILMath prevEWMA==0 branch).
        assert_eq!(m.ewma(), ONE_PCT);
        // Predicted is at least the baseline.
        assert!(f.predicted_ewma >= f.ewma_baseline);
    }

    #[test]
    fn ewma_converges_to_constant_input() {
        // Feeding a constant instant repeatedly drives the EWMA baseline to that constant.
        let mut m = VolModel::new();
        for _ in 0..200 {
            m.update(FIVE_PCT);
        }
        let diff = if m.ewma() > FIVE_PCT { m.ewma() - FIVE_PCT } else { FIVE_PCT - m.ewma() };
        // Should be within a hair of the input.
        assert!(diff < FIVE_PCT / 1000, "ewma={} target={}", m.ewma(), FIVE_PCT);
    }

    #[test]
    fn higher_deltas_give_higher_forecast() {
        let mut low = VolModel::new();
        let mut high = VolModel::new();
        for _ in 0..50 {
            low.update(ONE_PCT);
            high.update(FIVE_PCT);
        }
        let fl = low.forecast();
        let fh = high.forecast();
        assert!(
            fh.predicted_ewma > fl.predicted_ewma,
            "high={} low={}",
            fh.predicted_ewma,
            fl.predicted_ewma
        );
    }

    #[test]
    fn garch_reacts_to_a_shock_before_ewma_catches_up() {
        // Warm up calm, then a single large shock. The GARCH term should lift the forecast above
        // the still-low EWMA baseline immediately.
        let mut m = VolModel::new();
        for _ in 0..30 {
            m.update(ONE_PCT);
        }
        let calm = m.forecast();
        let big = 8 * FIVE_PCT; // 40% move
        let after = m.update(big);
        assert!(after.predicted_ewma > calm.predicted_ewma);
        // The clustering forecast should dominate the still-low smoothed baseline right after a shock.
        assert!(after.garch_forecast >= after.ewma_baseline);
    }

    #[test]
    fn output_is_bounded_under_runaway_input() {
        let mut m = VolModel::new();
        for _ in 0..1000 {
            m.update(u128::MAX); // adversarial: maximum possible instant every step
        }
        let f = m.forecast();
        assert!(f.predicted_ewma <= MAX_VOL_EWMA);
        assert!(f.garch_forecast <= MAX_VOL_EWMA);
        assert!(f.ewma_baseline <= MAX_VOL_EWMA);
    }

    #[test]
    fn deterministic_same_sequence_same_output() {
        let seq = [ONE_PCT, FIVE_PCT, 3 * ONE_PCT, 0, 2 * FIVE_PCT, ONE_PCT];
        let mut a = VolModel::new();
        let mut b = VolModel::new();
        let mut fa = VolForecast { predicted_ewma: 0, ewma_baseline: 0, garch_forecast: 0 };
        let mut fb = fa;
        for &s in &seq {
            fa = a.update(s);
            fb = b.update(s);
        }
        assert_eq!(fa, fb);
    }

    #[test]
    fn warm_start_from_ewma_preserves_baseline() {
        let m = VolModel::from_ewma(FIVE_PCT);
        let f = m.forecast();
        assert_eq!(f.ewma_baseline, FIVE_PCT);
    }

    #[test]
    fn zero_input_decays_toward_floor() {
        // Start hot, then feed zeros: EWMA decays toward 0, GARCH decays toward sqrt(omega floor).
        let mut m = VolModel::from_ewma(FIVE_PCT);
        for _ in 0..200 {
            m.update(0);
        }
        let f = m.forecast();
        assert!(f.ewma_baseline < ONE_PCT / 100); // EWMA baseline decayed near zero
        // GARCH floor: the stationary variance is omega/(1-beta) = 1e14/0.15 = 6.67e14 (WAD variance),
        // whose volatility level is wad_sqrt(6.67e14) ~= 2.58e16 WAD (about 2.58%). This non-zero floor
        // is deliberate: it keeps a minimum defensive fee even in dead-calm markets. Assert the forecast
        // has settled to that floor band, not to zero.
        let floor = 25_819_888_974_716_332u128; // ~2.58e16 WAD, the stationary GARCH vol level
        let diff = if f.garch_forecast > floor { f.garch_forecast - floor } else { floor - f.garch_forecast };
        assert!(diff < floor / 100, "garch={} floor={}", f.garch_forecast, floor);
        // Overall prediction equals the GARCH floor once the EWMA has decayed below it.
        assert_eq!(f.predicted_ewma, f.garch_forecast);
    }
}
