//! STRATUM EigenLayer AVS operator node binary.
//!
//! ## What this binary does
//!
//! The operator participates in the STRATUM EigenLayer AVS. Its full lifecycle:
//!
//! 1. Watch the chain for `EpochClosed` (from the hook) and LVR auction-open signals.
//! 2. Collect bids for the first-transaction (LVR) right and clear the auction off-chain
//!    using [`stratum_operator::clear_auction`] (deterministic, so all honest operators
//!    agree on the same winner and the same routing hash).
//! 3. Sign the resulting routing hash with the operator's secp256k1 key via
//!    [`stratum_operator::OperatorKey::sign_attestation`], producing the 65-byte
//!    `(r, s, v)` signature `MatchAttestation.submit(matchHash, sig)` accepts.
//! 4. Submit the attestation. Once `quorumThreshold` operators attest, `isAttested`
//!    returns true and the winning bidder (or the operator) calls
//!    `LVRAuctionReceiver.receiveYield(poolId, amount0, amount1, nonce)` to route the
//!    proceeds into the senior tranche.
//!
//! ## Offline core vs live node
//!
//! Everything in steps 2 and 3 - the auction clearing, the digest/hash computation, and
//! the signing - lives in the library crate and is fully unit-tested offline (`cargo test`).
//! That is the verifiable core.
//!
//! Step 1 (event subscription) and step 4 (transaction broadcast) require a chain RPC and
//! a signer-funded account. Those are the chain-I/O layer. To keep the core buildable and
//! testable without network access, this binary ships a deterministic dry-run demonstration
//! by default and documents exactly where the live `alloy`/`ethers` calls would slot in
//! (behind the `node` feature). The dry run exercises the real core code paths so the
//! produced signatures are genuine and contract-valid; only the RPC plumbing is stubbed.

use stratum_operator::{
    attestation_digest, clear_auction, recover_signer, AttestationDomain, Bid, OperatorKey,
};

fn main() {
    // ---- Configuration (live node would load these from env / keystore / RPC) ----
    // Operator private key. NEVER hardcode in production; load from a keystore or KMS.
    // Here we use a deterministic demo key (private key = 1) for a reproducible dry run.
    let mut secret = [0u8; 32];
    secret[31] = 1;
    let key = OperatorKey::from_bytes(&secret).expect("valid demo key");

    // Domain mirrors what MatchAttestation reads on-chain. In the live node these come from
    // chainId (eth_chainId), the deployed contract address, and operatorSetVersion (a view call).
    let domain = AttestationDomain {
        chain_id: 1301, // Unichain Sepolia
        contract_addr: [0xCAu8; 20],
        operator_set_version: 1,
    };

    println!("STRATUM EigenLayer AVS operator (dry run)");
    println!("operator address: {}", key.address_hex());
    println!(
        "domain: chainId={} contract=0x{} version={}",
        domain.chain_id,
        hex::encode(domain.contract_addr),
        domain.operator_set_version
    );

    // ---- Step 2: clear an example LVR auction (real core logic) ----
    let pool_id = [0x33u8; 32];
    let bids = [
        Bid {
            bidder: [0x11u8; 20],
            amount0: 500,
            amount1: 500,
        },
        Bid {
            bidder: [0x22u8; 20],
            amount0: 950,
            amount1: 100,
        },
    ];
    // Route 80% of the winning bid to the senior tranche under nonce 7.
    let clearing = clear_auction(pool_id, &bids, 8000, 7).expect("non-empty auction");
    println!(
        "auction winner: 0x{}  proceeds0={} proceeds1={} nonce={}",
        hex::encode(clearing.winner),
        clearing.proceeds0,
        clearing.proceeds1,
        clearing.nonce
    );
    println!("routingHash: 0x{}", hex::encode(clearing.routing_hash));

    // ---- Step 3: sign the routing hash (real ECDSA over the exact on-chain digest) ----
    let sig = key
        .sign_attestation(&domain, clearing.routing_hash)
        .expect("signing succeeds");
    println!("attestation signature (65-byte r||s||v): {}", sig.to_hex());

    // Self-verify exactly as MatchAttestation.submit will: recover over the EIP-191 digest.
    let digest = attestation_digest(&domain, clearing.routing_hash);
    let recovered = recover_signer(&digest, &sig).expect("recover");
    assert_eq!(recovered, key.address(), "recovered signer must be operator");
    println!("self-check: recovered signer == operator address (submit would accept)");

    // ---- Step 4 (live only): broadcast ----
    // Behind the `node` feature, the following would run against a real RPC:
    //   matchAttestation.submit(clearing.routing_hash, sig.bytes)  // until quorum
    //   lvrAuctionReceiver.receiveYield(pool_id, proceeds0, proceeds1, nonce)
    // Implemented with alloy/ethers providers + a funded signer. Omitted here so the
    // crate builds and tests fully offline. See README "Live node" for the wiring.
    #[cfg(feature = "node")]
    {
        eprintln!("`node` feature enabled but live RPC wiring is intentionally not bundled offline.");
    }

    println!("dry run complete.");
}
