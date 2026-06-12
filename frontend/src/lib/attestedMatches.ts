/**
 * Recover the real, attested matchHashes for the MatchAttestation lab straight from chain.
 *
 * The full 32-byte matchHashes are not published in any doc - they only exist in the contract's
 * `AttestationSubmitted(bytes32 indexed matchHash, address indexed operator, uint256 count)` logs.
 * A public-RPC `getLogs` would need ~60 windowed calls to cover the ~600k blocks back to when the
 * attestations were submitted (RPC caps the range at 10k blocks). The explorer's logs API has no
 * such cap, so one HTTP call returns every attestation. We fall back gracefully (empty list) if the
 * explorer is unreachable; the lab still works via the pre-filled default hash and manual paste.
 */

import { UNICHAIN_SEPOLIA } from "../config/addresses";

/** keccak256("AttestationSubmitted(bytes32,address,uint256)") - the indexed matchHash is topic[1]. */
const ATTESTATION_SUBMITTED_TOPIC0 =
  "0xc9213e80b1d337fcc3155009e49db5276cde10ab58b9a0d2af698e37a54c8feb";

export interface AttestedMatch {
  /** The bytes32 matchHash an operator attested to. */
  matchHash: `0x${string}`;
  /** Highest attestation count seen for this hash (later logs carry the running total). */
  count: number;
}

/**
 * Fetch the distinct attested matchHashes for a MatchAttestation contract, newest first.
 * Returns [] on any failure so callers can degrade to the manual-paste path.
 */
export async function loadAttestedMatches(
  attestationAddress: string,
  signal?: AbortSignal
): Promise<AttestedMatch[]> {
  const base = UNICHAIN_SEPOLIA.blockExplorers.default.url.replace(/\/$/, "");
  const url =
    `${base}/api?module=logs&action=getLogs&fromBlock=0&toBlock=latest` +
    `&address=${attestationAddress}&topic0=${ATTESTATION_SUBMITTED_TOPIC0}`;

  try {
    const res = await fetch(url, { signal });
    if (!res.ok) return [];
    const body = (await res.json()) as { result?: Array<{ topics: string[]; data: string }> };
    const logs = Array.isArray(body.result) ? body.result : [];

    // Dedupe by matchHash, keeping the highest running count. Iterate in chain order (oldest first),
    // then reverse so the most recently attested match surfaces at the top of the picker.
    const byHash = new Map<string, number>();
    for (const log of logs) {
      const matchHash = log.topics?.[1];
      if (!matchHash || matchHash.length !== 66) continue;
      const count = log.data && log.data !== "0x" ? Number(BigInt(log.data)) : 0;
      const prev = byHash.get(matchHash) ?? 0;
      byHash.set(matchHash, Math.max(prev, count));
    }

    return Array.from(byHash.entries())
      .map(([matchHash, count]) => ({ matchHash: matchHash as `0x${string}`, count }))
      .reverse();
  } catch {
    return [];
  }
}
