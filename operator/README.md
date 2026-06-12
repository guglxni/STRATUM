# STRATUM EigenLayer AVS operator node

Rust crate for the STRATUM EigenLayer AVS operator. It runs the LVR (Loss-Versus-Rebalancing)
auction clearing and produces the ECDSA match attestations that the on-chain
`MatchAttestation` and `LVRAuctionReceiver` contracts accept.

The crate is split into a verifiable, offline-testable **core** (library) and a thin
**chain-I/O** layer (the binary's documented event loop).

## What it does

1. Watches the chain for `EpochClosed` (from the hook) and LVR auction-open signals. (live layer)
2. Clears the LVR auction off-chain: highest bid wins, deterministic tie-break, so every
   honest operator agrees on the same winner and the same routing hash. (core)
3. Computes the senior-tranche proceeds split and the on-chain `routingHash`. (core)
4. Signs the routing hash with the operator's secp256k1 key, producing the 65-byte
   `(r, s, v)` signature `MatchAttestation.submit` accepts. (core)
5. Submits attestations until quorum, then routes proceeds via
   `LVRAuctionReceiver.receiveYield`. (live layer)

## Exact on-chain formulas this crate reproduces

These are reproduced byte-for-byte and verified by tests against the Solidity source in
`src/peripherals/eigenlayer/`.

### MatchAttestation digest (`attestation.rs`, `abi.rs`)

```text
commitment = keccak256(abi.encode(uint256 chainId, address(this), uint256 operatorSetVersion, bytes32 matchHash))
digest     = keccak256("\x19Ethereum Signed Message:\n32" || commitment)
```

The operator signs `digest` with secp256k1. The contract's `submit` recovers the signer
with `ecrecover(digest, v, r, s)` and requires `recovered == msg.sender`. The crate:

- encodes the four-word `abi.encode` tuple exactly (uint256, left-padded address, uint256, bytes32),
- applies the EIP-191 `"\x19Ethereum Signed Message:\n32"` prefix,
- emits `v in {27, 28}` (`27 + recovery_id`),
- normalizes and enforces **low-`s`** (EIP-2): `s <= 0x7FFFFFFF...681B20A0`, the same
  `SECP256K1_HALF_ORDER` the contract checks. High-`s` signatures are rejected before they
  could ever be submitted.

### LVRAuctionReceiver routing hash (`lvr_auction.rs`, `abi.rs`)

```text
routingHash(id, amount0, amount1, nonce) = keccak256(abi.encode(bytes32 id, uint256 amount0, uint256 amount1, uint256 nonce))
```

`PoolId` is a `type PoolId is bytes32`, so it encodes as a raw 32-byte word (not an address).

## Crates used

- `k256` (with `ecdsa`, `arithmetic`): pure-Rust secp256k1 signing, recovery, and low-`s`
  normalization. Builds offline.
- `tiny-keccak` (`keccak` feature): pure-Rust keccak256 (Ethereum keccak, not NIST SHA3-256).
- `hex`: hex formatting for logs and test vectors.

No oracle, price feed, or external data source is used (consistent with the STRATUM golden
rules; the auction ranks bids by their raw routed `amount0 + amount1`).

## Layout

```
operator/
  Cargo.toml          lib + bin; `node` feature gates the (documented) live RPC layer
  src/
    lib.rs            crate root, re-exports, end-to-end core integration test
    abi.rs            minimal abi.encode + keccak256 for the two on-chain tuples
    attestation.rs    EIP-191 digest, secp256k1 signing, recovery, low-s enforcement
    lvr_auction.rs    auction clearing, senior split, routingHash reproduction
    main.rs           operator loop (documented); offline dry run by default
  README.md
```

## Build and test

```sh
cd operator
cargo test       # 22 tests, all offline, no network
cargo run        # deterministic dry run: clears an auction, signs, self-verifies recovery
```

`cargo test` covers:

- keccak256 known-answer vectors (`keccak256("")`, `keccak256("abc")`),
- ABI word layout (uint256, left-padded address, bytes32),
- attestation digest determinism and sensitivity to every domain field
  (chainId, contract, operatorSetVersion, matchHash),
- an independent step-by-step recompute of the Solidity digest formula matching the
  production path,
- signature round-trip (`recover(digest, sig) == operator address`),
- low-`s` enforcement across many signatures and rejection of high-`s` on recover,
- the known address for private key = 1 (`0x7e5f4552091a69125d5dfcb7b8c2659029395bdf`),
- auction: highest bid wins, deterministic tie-break by lower address (order-independent),
  proceeds split floor math, overflow-safe `mul_div`, and `routingHash` equality with the
  receiver formula.

## Offline-tested core vs live node (honest note)

The **core** - auction clearing, ABI/keccak/digest computation, and ECDSA signing -
is implemented in the library crate and fully unit-tested offline. The signatures it
produces are genuine and contract-valid: the binary's dry run re-runs the real signing
path and verifies `ecrecover` returns the operator address, exactly as `submit` does.

The **live node** parts - subscribing to `EpochClosed`/auction events and broadcasting the
`submit` and `receiveYield` transactions - require a chain RPC and a funded signer. Those
are intentionally kept out of the verifiable core and out of the default build so the crate
compiles and tests without network access. They would slot in behind the `node` feature
using `alloy`/`ethers` providers; the exact call sites are documented in `main.rs` step 4.
This boundary is deliberate: the cryptographic correctness that gates real funds is the part
that is tested, and it does not depend on any network I/O.
