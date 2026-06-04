# Peripherals (Phase 3+)

Optional modules implementing `IPeripheral`. The core hook never imports these directly.

- `reactive/` - EpochSettler, CoverageMonitor, ReserveBalancer
- `across/` - CrossPoolHedgingRouter
- `brevis/` - ZK proof verifier shims
- `eigenlayer/` - LVR auction and attestation
- `stylus/` - Solidity shim to Arbitrum Stylus matcher

Core-only CI must stay green with this directory empty or stubbed.
