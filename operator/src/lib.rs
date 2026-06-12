//! STRATUM EigenLayer AVS operator node: verifiable core.
//!
//! This crate contains the offline-testable, deterministic core that an AVS operator runs:
//!
//! - [`abi`]: minimal `abi.encode` + keccak256 reproducing the exact byte layout of the
//!   STRATUM Solidity contracts (`MatchAttestation`, `LVRAuctionReceiver`).
//! - [`attestation`]: computes the EIP-191 attestation digest and signs it with the
//!   operator's secp256k1 key, producing the 65-byte `(r, s, v)` low-`s` signature that
//!   `MatchAttestation.submit` accepts (`ecrecover == msg.sender`, EIP-2 enforced).
//! - [`lvr_auction`]: LVR auction clearing (highest bid wins, deterministic tie-break),
//!   senior-tranche proceeds split, and the on-chain `routingHash` reproduction.
//!
//! The chain-I/O event loop (watching `EpochClosed` / auction events, broadcasting the
//! `submit` and `receiveYield` transactions) is a documented thin layer in `main.rs`,
//! intentionally kept out of the verifiable core so `cargo test` runs fully offline.
//!
//! On-chain formulas reproduced here (verified by tests against the Solidity source):
//!
//! ```text
//! MatchAttestation.attestationDigest(matchHash):
//!   commitment = keccak256(abi.encode(chainId, address(this), operatorSetVersion, matchHash))
//!   digest     = keccak256("\x19Ethereum Signed Message:\n32" || commitment)
//!
//! LVRAuctionReceiver.routingHash(id, amount0, amount1, nonce):
//!   keccak256(abi.encode(id, amount0, amount1, nonce))
//! ```

pub mod abi;
pub mod attestation;
pub mod lvr_auction;

pub use attestation::{
    attestation_digest, recover_signer, AttestationDomain, AttestationError, EthSignature,
    OperatorKey,
};
pub use lvr_auction::{clear_auction, AuctionClearing, AuctionError, Bid};

#[cfg(test)]
mod integration_tests {
    use super::*;

    /// End-to-end core flow: clear an auction, then attest the resulting routing hash.
    /// The signed routing-hash attestation is what gates `receiveYield` on-chain.
    #[test]
    fn auction_then_attest_routing_hash() {
        let pool = [0x33u8; 32];
        let bids = [
            Bid {
                bidder: [1u8; 20],
                amount0: 500,
                amount1: 500,
            },
            Bid {
                bidder: [2u8; 20],
                amount0: 950,
                amount1: 100,
            },
        ];
        // Bidder 2 has higher value (1050 > 1000), so it wins outright.
        let clearing = clear_auction(pool, &bids, 8000, 7).unwrap();
        assert_eq!(clearing.winner, [2u8; 20]);

        // Operator attests the routing hash that LVRAuctionReceiver will derive.
        let mut secret = [0u8; 32];
        secret[31] = 1;
        let key = OperatorKey::from_bytes(&secret).unwrap();
        let domain = AttestationDomain {
            chain_id: 1301,
            contract_addr: [0xCAu8; 20],
            operator_set_version: 1,
        };
        let sig = key
            .sign_attestation(&domain, clearing.routing_hash)
            .unwrap();

        // The contract recovers the signer over the same digest and checks == msg.sender.
        let digest = attestation_digest(&domain, clearing.routing_hash);
        assert_eq!(recover_signer(&digest, &sig).unwrap(), key.address());
    }
}
