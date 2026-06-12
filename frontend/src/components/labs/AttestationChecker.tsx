/**
 * EigenLayer Attestation Checker (spec §9.1). Read-only: enter a matchHash and check
 * isAttested / attestationCount against the live MatchAttestation quorum on Unichain Sepolia. Also
 * shows the operator set (operatorCount, quorumThreshold). The write path submit() is operator-only
 * and never exposed here (§9.3).
 *
 * To make the lab self-proving rather than asking judges for a hash they cannot know, it loads the
 * real attested matchHashes straight from the contract's AttestationSubmitted logs (see
 * lib/attestedMatches.ts) and pre-fills the documented default so "Check" returns ATTESTED in one
 * click.
 */

import { useEffect, useState } from "react";
import { usePublicClient, useReadContract } from "wagmi";
import { isHex } from "viem";
import LabCard from "./LabCard";
import { MATCH_ATTESTATION_ABI } from "../../abis/matchAttestation";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../../config/addresses";
import { explorerAddress } from "../../config/explorers";
import { loadAttestedMatches, type AttestedMatch } from "../../lib/attestedMatches";

interface CheckResult {
  attested: boolean;
  count: bigint;
}

export default function AttestationChecker() {
  const attestation = STRATUM_ADDRESSES.matchAttestation as `0x${string}`;
  const client = usePublicClient({ chainId: UNICHAIN_SEPOLIA.id });
  const [hash, setHash] = useState(STRATUM_ADDRESSES.demoMatchHash);
  const [res, setRes] = useState<CheckResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [matches, setMatches] = useState<AttestedMatch[] | null>(null);

  const { data: operatorCount } = useReadContract({
    address: attestation,
    abi: MATCH_ATTESTATION_ABI,
    functionName: "operatorCount",
    chainId: UNICHAIN_SEPOLIA.id,
    query: { enabled: !!STRATUM_ADDRESSES.matchAttestation },
  });
  const { data: quorum } = useReadContract({
    address: attestation,
    abi: MATCH_ATTESTATION_ABI,
    functionName: "quorumThreshold",
    chainId: UNICHAIN_SEPOLIA.id,
    query: { enabled: !!STRATUM_ADDRESSES.matchAttestation },
  });

  // Pull the real attested hashes from chain so judges can pick one instead of hunting for a value.
  useEffect(() => {
    const ctrl = new AbortController();
    loadAttestedMatches(attestation, ctrl.signal).then(setMatches);
    return () => ctrl.abort();
  }, [attestation]);

  const valid = isHex(hash) && hash.length === 66;

  const runCheck = async (h: string) => {
    if (!client || !(isHex(h) && h.length === 66)) return;
    setBusy(true);
    setErr("");
    setRes(null);
    try {
      const [attested, count] = await Promise.all([
        client.readContract({ address: attestation, abi: MATCH_ATTESTATION_ABI, functionName: "isAttested", args: [h as `0x${string}`] }),
        client.readContract({ address: attestation, abi: MATCH_ATTESTATION_ABI, functionName: "attestationCount", args: [h as `0x${string}`] }),
      ]);
      setRes({ attested: attested as boolean, count: count as bigint });
    } catch (e) {
      setErr(e instanceof Error ? e.message.slice(0, 140) : "read failed");
    } finally {
      setBusy(false);
    }
  };

  const pick = (m: AttestedMatch) => {
    setHash(m.matchHash);
    runCheck(m.matchHash);
  };

  return (
    <LabCard
      protocol="EigenLayer · MatchAttestation"
      enables="M-of-N operator attestation that gates cross-chain bridgeReserve and LVR routing (FR-24)."
      trigger="Read isAttested(matchHash) against the live quorum."
      klass="R0"
      status="live"
      chainHint="Reading Unichain Sepolia"
      proofHref={explorerAddress(STRATUM_ADDRESSES.matchAttestation)}
      proofLabel="Attestation contract"
    >
      <p className="caption muted" style={{ marginBottom: 10 }}>
        Operator set:{" "}
        <span className="mono">
          {operatorCount !== undefined ? operatorCount.toString() : "…"} operators · quorum{" "}
          {quorum !== undefined ? quorum.toString() : "…"}
        </span>
      </p>

      <div className="lab-form">
        <label className="lab-field lab-field-wide">
          <span>matchHash (bytes32)</span>
          <input
            className="input-pill mono"
            value={hash}
            placeholder="0x… 32-byte match hash"
            onChange={(e) => setHash(e.target.value)}
          />
        </label>
        <button className="btn-pill btn-pill-sm" onClick={() => runCheck(hash)} disabled={!valid || busy}>
          {busy ? "Checking…" : "Check"}
        </button>
      </div>

      {/* Live picker: real attested hashes pulled from the contract's AttestationSubmitted logs. */}
      {matches && matches.length > 0 && (
        <div className="attest-picker">
          <span className="caption muted">Attested on-chain:</span>
          {matches.map((m) => (
            <button
              key={m.matchHash}
              className={`chip chip-mono ${hash.toLowerCase() === m.matchHash.toLowerCase() ? "chip-selected" : ""}`}
              title={m.matchHash}
              onClick={() => pick(m)}
            >
              {m.matchHash.slice(0, 10)}…{m.matchHash.slice(-4)}
            </button>
          ))}
        </div>
      )}

      {res && (
        <p className="lab-result">
          <span className={res.attested ? "badge badge-ok" : "badge badge-neutral"}>
            {res.attested ? "ATTESTED" : "not attested"}
          </span>{" "}
          <span className="caption muted">
            {res.count.toString()} of {quorum !== undefined ? quorum.toString() : "?"} operator attestations
          </span>
        </p>
      )}
      {err && <p className="caption lab-err">{err}</p>}

      {/* Concise "how to obtain a matchHash" explainer (the original card just said "from LIVE_SYSTEM"). */}
      <details className="lab-how">
        <summary>How to get a matchHash &amp; test it</summary>
        <ol className="lab-how-list">
          <li>
            A matchHash is{" "}
            <span className="mono">keccak256(abi.encode(id, amount0, amount1, nonce))</span> over a bridge
            or LVR-routing result, computed by the operator node (<span className="mono">operator/</span>) or the
            CPHR - not a user input.
          </li>
          <li>
            Each operator signs an EIP-191 domain-separated digest of it and calls{" "}
            <span className="mono">submit()</span>; the contract emits{" "}
            <span className="mono">AttestationSubmitted(matchHash, operator, count)</span>.
          </li>
          <li>
            The chips above are those exact emitted hashes, read live from the explorer logs API. Click one
            (or paste your own) and <b>Check</b> calls <span className="mono">isAttested()</span> on-chain - ATTESTED
            means the M-of-N quorum was reached.
          </li>
        </ol>
      </details>
    </LabCard>
  );
}
