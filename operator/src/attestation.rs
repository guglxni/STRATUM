//! Match attestation signing.
//!
//! Reproduces the exact digest the on-chain `MatchAttestation` contract verifies, and
//! produces a 65-byte `(r, s, v)` secp256k1 signature that `MatchAttestation.submit`
//! will accept.
//!
//! On-chain digest (see `MatchAttestation.attestationDigest`):
//!
//! ```text
//! commitment = keccak256(abi.encode(chainId, address(this), operatorSetVersion, matchHash))
//! digest     = keccak256("\x19Ethereum Signed Message:\n32" || commitment)
//! ```
//!
//! The operator signs `digest` with its secp256k1 key. `submit` recovers the signer with
//! `ecrecover(digest, v, r, s)` and requires `recovered == msg.sender`, so the operator
//! key MUST correspond to the operator's registered EVM address.
//!
//! EIP-2 (`s` malleability): the contract rejects `s > SECP256K1_HALF_ORDER`. `k256`
//! `sign_prehash_recoverable` already returns the low-`s` normalized form, and we assert
//! it here as a belt-and-braces invariant. `v` is encoded as `27 + recovery_id` so the
//! contract's `ecrecover` sees the canonical 27/28 value.

use k256::ecdsa::{RecoveryId, Signature, SigningKey, VerifyingKey};

use crate::abi::{attestation_commitment_hash, keccak256};

/// secp256k1 group order, big-endian. Half of this is the EIP-2 high-`s` boundary.
/// n = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
/// half-order (n-1)/2 used by the contract:
/// 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
const SECP256K1_HALF_ORDER: [u8; 32] = [
    0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D, 0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
];

/// The domain parameters that bind a signature to a specific chain, deployment, and
/// operator-set epoch. These mirror the values the contract reads at verification time.
#[derive(Clone, Copy, Debug)]
pub struct AttestationDomain {
    pub chain_id: u128,
    /// `address(this)` of the deployed `MatchAttestation` contract.
    pub contract_addr: [u8; 20],
    /// `operatorSetVersion` current at the moment of signing.
    pub operator_set_version: u128,
}

/// A 65-byte Ethereum-style signature: `r (32) || s (32) || v (1)` with `v in {27, 28}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EthSignature {
    pub bytes: [u8; 65],
}

impl EthSignature {
    pub fn r(&self) -> [u8; 32] {
        let mut r = [0u8; 32];
        r.copy_from_slice(&self.bytes[0..32]);
        r
    }
    pub fn s(&self) -> [u8; 32] {
        let mut s = [0u8; 32];
        s.copy_from_slice(&self.bytes[32..64]);
        s
    }
    pub fn v(&self) -> u8 {
        self.bytes[64]
    }
    pub fn to_hex(&self) -> String {
        format!("0x{}", hex::encode(self.bytes))
    }
}

/// Compute the domain-separated commitment hash:
/// `keccak256(abi.encode(chainId, contract, version, matchHash))`.
pub fn attestation_commitment(domain: &AttestationDomain, match_hash: [u8; 32]) -> [u8; 32] {
    attestation_commitment_hash(
        domain.chain_id,
        domain.contract_addr,
        domain.operator_set_version,
        match_hash,
    )
}

/// Compute the exact EIP-191 digest the contract verifies:
/// `keccak256("\x19Ethereum Signed Message:\n32" || commitment)`.
pub fn attestation_digest(domain: &AttestationDomain, match_hash: [u8; 32]) -> [u8; 32] {
    let commitment = attestation_commitment(domain, match_hash);
    let mut preimage = Vec::with_capacity(28 + 32);
    preimage.extend_from_slice(b"\x19Ethereum Signed Message:\n32");
    preimage.extend_from_slice(&commitment);
    keccak256(&preimage)
}

/// Derive the 20-byte EVM address from a verifying (public) key.
pub fn address_from_verifying_key(vk: &VerifyingKey) -> [u8; 20] {
    // Uncompressed SEC1 point is 0x04 || X(32) || Y(32); address = last 20 bytes of keccak(X||Y).
    let point = vk.to_encoded_point(false);
    let bytes = point.as_bytes();
    debug_assert_eq!(bytes[0], 0x04);
    let hash = keccak256(&bytes[1..]); // strip the 0x04 prefix
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&hash[12..32]);
    addr
}

/// An AVS operator's signing identity.
pub struct OperatorKey {
    signing_key: SigningKey,
    address: [u8; 20],
}

impl OperatorKey {
    /// Build from a 32-byte private key.
    pub fn from_bytes(secret: &[u8; 32]) -> Result<Self, AttestationError> {
        let signing_key =
            SigningKey::from_bytes(secret.into()).map_err(|_| AttestationError::InvalidKey)?;
        let address = address_from_verifying_key(signing_key.verifying_key());
        Ok(Self {
            signing_key,
            address,
        })
    }

    /// The operator's EVM address (must equal the registered operator / `msg.sender`).
    pub fn address(&self) -> [u8; 20] {
        self.address
    }

    pub fn address_hex(&self) -> String {
        format!("0x{}", hex::encode(self.address))
    }

    /// Sign a match attestation for the given domain, producing the 65-byte signature
    /// `MatchAttestation.submit` accepts (low-`s`, `v in {27,28}`).
    pub fn sign_attestation(
        &self,
        domain: &AttestationDomain,
        match_hash: [u8; 32],
    ) -> Result<EthSignature, AttestationError> {
        let digest = attestation_digest(domain, match_hash);
        self.sign_digest(&digest)
    }

    /// Sign a raw 32-byte digest (already EIP-191 wrapped). Exposed for testing and for
    /// signing digests produced by `attestation_digest`.
    pub fn sign_digest(&self, digest: &[u8; 32]) -> Result<EthSignature, AttestationError> {
        // k256 returns a low-s normalized signature plus a recovery id.
        let (sig, recid): (Signature, RecoveryId) = self
            .signing_key
            .sign_prehash_recoverable(digest)
            .map_err(|_| AttestationError::SigningFailed)?;

        // Normalize s to the low half (defensive; k256 already does this for recoverable sign).
        let sig = sig.normalize_s().unwrap_or(sig);

        let r = sig.r().to_bytes();
        let s = sig.s().to_bytes();

        let mut out = [0u8; 65];
        out[0..32].copy_from_slice(r.as_ref());
        out[32..64].copy_from_slice(s.as_ref());
        // v = 27 + recovery_id (canonical Ethereum encoding).
        out[64] = 27 + recid.to_byte();

        let eth_sig = EthSignature { bytes: out };

        // Enforce EIP-2 low-s as the contract does, and confirm we can recover ourselves.
        if !is_low_s(&eth_sig.s()) {
            return Err(AttestationError::HighS);
        }
        let recovered = recover_signer(digest, &eth_sig)?;
        if recovered != self.address {
            return Err(AttestationError::RecoveryMismatch);
        }
        Ok(eth_sig)
    }
}

/// Recover the signer's 20-byte address from a digest and a 65-byte signature,
/// mirroring the contract's `ecrecover`-based `_recoverSigner`.
pub fn recover_signer(digest: &[u8; 32], sig: &EthSignature) -> Result<[u8; 20], AttestationError> {
    if !is_low_s(&sig.s()) {
        return Err(AttestationError::HighS);
    }
    let v = sig.v();
    if v != 27 && v != 28 {
        return Err(AttestationError::BadV);
    }
    let recid =
        RecoveryId::from_byte(v - 27).ok_or(AttestationError::RecoveryFailed)?;

    let mut rs = [0u8; 64];
    rs[0..32].copy_from_slice(&sig.r());
    rs[32..64].copy_from_slice(&sig.s());
    let signature = Signature::from_slice(&rs).map_err(|_| AttestationError::RecoveryFailed)?;

    let vk = VerifyingKey::recover_from_prehash(digest, &signature, recid)
        .map_err(|_| AttestationError::RecoveryFailed)?;
    Ok(address_from_verifying_key(&vk))
}

/// EIP-2 check: `s <= (n-1)/2`.
pub fn is_low_s(s: &[u8; 32]) -> bool {
    // Big-endian lexicographic comparison equals numeric comparison for equal-length BE arrays.
    *s <= SECP256K1_HALF_ORDER
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttestationError {
    InvalidKey,
    SigningFailed,
    HighS,
    BadV,
    RecoveryFailed,
    RecoveryMismatch,
}

impl core::fmt::Display for AttestationError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let s = match self {
            AttestationError::InvalidKey => "invalid secp256k1 private key",
            AttestationError::SigningFailed => "ECDSA signing failed",
            AttestationError::HighS => "signature s value is in the high half (EIP-2 reject)",
            AttestationError::BadV => "signature v is not 27 or 28",
            AttestationError::RecoveryFailed => "signer recovery failed",
            AttestationError::RecoveryMismatch => "recovered signer does not match operator",
        };
        f.write_str(s)
    }
}

impl std::error::Error for AttestationError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_domain() -> AttestationDomain {
        AttestationDomain {
            chain_id: 1301,
            contract_addr: [0xCAu8; 20],
            operator_set_version: 1,
        }
    }

    fn test_key() -> OperatorKey {
        // Deterministic non-zero key for reproducible tests.
        let mut secret = [0u8; 32];
        secret[31] = 1; // private key = 1 (valid secp256k1 scalar)
        OperatorKey::from_bytes(&secret).unwrap()
    }

    #[test]
    fn digest_is_deterministic() {
        let domain = test_domain();
        let mh = [0x42u8; 32];
        let d1 = attestation_digest(&domain, mh);
        let d2 = attestation_digest(&domain, mh);
        assert_eq!(d1, d2);
    }

    #[test]
    fn digest_changes_with_domain_fields() {
        let mh = [0x42u8; 32];
        let base = attestation_digest(&test_domain(), mh);

        let mut d = test_domain();
        d.chain_id = 1;
        assert_ne!(attestation_digest(&d, mh), base);

        let mut d = test_domain();
        d.operator_set_version = 2;
        assert_ne!(attestation_digest(&d, mh), base);

        let mut d = test_domain();
        d.contract_addr = [0xFFu8; 20];
        assert_ne!(attestation_digest(&d, mh), base);
    }

    /// Hard-coded digest vector. The expected value is computed by an independent
    /// reimplementation of the exact Solidity keccak steps inside the test, so a
    /// regression in the production path (abi layout, prefix, ordering) is caught.
    #[test]
    fn digest_matches_independent_solidity_recompute() {
        let domain = AttestationDomain {
            chain_id: 1301,
            contract_addr: [0xCAu8; 20],
            operator_set_version: 1,
        };
        let match_hash = [0xABu8; 32];

        // Independent recompute, step by step, of the Solidity formula.
        // 1. abi.encode(uint256 chainId, address, uint256 version, bytes32)
        let mut enc = Vec::new();
        // chainId = 1301 = 0x0515
        let mut w = [0u8; 32];
        w[30] = 0x05;
        w[31] = 0x15;
        enc.extend_from_slice(&w);
        // address left padded
        let mut w = [0u8; 32];
        for b in w.iter_mut().take(32).skip(12) {
            *b = 0xCA;
        }
        enc.extend_from_slice(&w);
        // version = 1
        let mut w = [0u8; 32];
        w[31] = 1;
        enc.extend_from_slice(&w);
        // matchHash
        enc.extend_from_slice(&[0xABu8; 32]);
        assert_eq!(enc.len(), 128);

        let commitment = keccak256(&enc);
        let mut preimage = Vec::new();
        preimage.extend_from_slice(b"\x19Ethereum Signed Message:\n32");
        preimage.extend_from_slice(&commitment);
        let expected = keccak256(&preimage);

        assert_eq!(attestation_digest(&domain, match_hash), expected);
        // Also assert the commitment path is wired identically.
        assert_eq!(attestation_commitment(&domain, match_hash), commitment);
    }

    #[test]
    fn signature_round_trips_to_signer() {
        let key = test_key();
        let domain = test_domain();
        let mh = [0x42u8; 32];
        let sig = key.sign_attestation(&domain, mh).unwrap();
        let digest = attestation_digest(&domain, mh);
        let recovered = recover_signer(&digest, &sig).unwrap();
        assert_eq!(recovered, key.address());
    }

    #[test]
    fn signature_is_low_s() {
        let key = test_key();
        let domain = test_domain();
        // Sign many distinct match hashes; every signature must be low-s.
        for i in 0u8..32 {
            let sig = key.sign_attestation(&domain, [i; 32]).unwrap();
            assert!(is_low_s(&sig.s()), "signature {i} had high s");
            assert!(sig.v() == 27 || sig.v() == 28);
        }
    }

    #[test]
    fn tampered_digest_recovers_wrong_signer() {
        let key = test_key();
        let domain = test_domain();
        let mh = [0x42u8; 32];
        let sig = key.sign_attestation(&domain, mh).unwrap();
        let mut digest = attestation_digest(&domain, mh);
        digest[0] ^= 0xFF; // tamper
        let recovered = recover_signer(&digest, &sig).unwrap();
        assert_ne!(recovered, key.address());
    }

    #[test]
    fn high_s_is_rejected_on_recover() {
        // Build a signature with s set to all 0xFF (definitely high) and confirm rejection.
        let mut bytes = [0u8; 65];
        bytes[32..64].copy_from_slice(&[0xFFu8; 32]);
        bytes[64] = 27;
        let sig = EthSignature { bytes };
        let digest = [0u8; 32];
        assert_eq!(recover_signer(&digest, &sig), Err(AttestationError::HighS));
    }

    #[test]
    fn known_address_for_privkey_one() {
        // The public address for private key = 1 is a well-known secp256k1 value.
        let key = test_key();
        assert_eq!(
            key.address_hex(),
            "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"
        );
    }
}
