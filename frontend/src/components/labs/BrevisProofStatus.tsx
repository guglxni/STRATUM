/**
 * Brevis proof status (spec §8.3 + §15.1). Read-only and deliberately honest: the verifier shim is
 * deployed on-chain and local proof verification succeeds, but the hosted gateway only serves the
 * Ethereum-mainnet → Arbitrum-One route, so the Sepolia testnet route is unavailable. Never shows a
 * green "proof submitted" — that would be a fake success.
 */

import LabCard from "./LabCard";
import { STRATUM_ADDRESSES } from "../../config/addresses";
import { explorerAddress } from "../../config/explorers";

export default function BrevisProofStatus() {
  return (
    <LabCard
      protocol="Brevis"
      enables="ZK time-weighted distribution and IL-attribution proofs at settlement (FR-21 / FR-22)."
      trigger="BrevisProofRequested on the settlement path (withdraw)."
      klass="R0"
      status="partial"
      chainHint="Shim on Unichain Sepolia"
      proofHref={explorerAddress(STRATUM_ADDRESSES.brevisShim)}
      proofLabel="Verifier shim"
    >
      <ul className="lab-bullets">
        <li>
          <span className="badge badge-ok">deployed</span> Verifier shim is live on-chain; the settlement
          path requests proofs and falls back to deterministic accounting (FR-22) when none is available.
        </li>
        <li>
          <span className="badge badge-ok">verified</span> Circuit compiles and <b>local</b> proof
          verification succeeds.
        </li>
        <li>
          <span className="badge badge-watch">gateway-limited</span> The hosted gateway currently serves
          only Ethereum mainnet → Arbitrum One; the Sepolia testnet route returns SMT-info-missing, so live
          proof submission is not self-servable on testnet.
        </li>
      </ul>
      <p className="fine-print" style={{ marginTop: 8 }}>
        This card stays amber by design: on testnet we show the deployed shim and local verification, not a
        fake gateway success.
      </p>
    </LabCard>
  );
}
