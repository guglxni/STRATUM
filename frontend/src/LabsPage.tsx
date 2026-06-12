/**
 * #labs route: the Feature Labs hub (docs/FRONTEND_PROTOCOL_INTERACTIVITY.md §2). One card per
 * integration — read-only "try it" calls, honest status, and on-chain proof. The evidence drawer at
 * the top lets a judge verify every claim without a repo checkout.
 */

import PageNav from "./components/PageNav";
import EvidenceDrawer from "./components/labs/EvidenceDrawer";
import ReactiveStepper from "./components/labs/ReactiveStepper";
import StylusVolLab from "./components/labs/StylusVolLab";
import AttestationChecker from "./components/labs/AttestationChecker";
import AcrossTimeline from "./components/labs/AcrossTimeline";
import BrevisProofStatus from "./components/labs/BrevisProofStatus";
import ChainlinkBenchmarkCard from "./components/labs/ChainlinkBenchmarkCard";

export default function LabsPage() {
  return (
    <div className="page-parchment">
      <PageNav active="labs" />
      <main className="dash-main container-wide">
        <div className="dash-header">
          <div>
            <h2 style={{ margin: 0 }}>Feature labs</h2>
            <div className="sub">
              Each integration as a clickable feature: read-only calls anyone can run, honest status, and
              on-chain proof. Core tranching works with every peripheral disabled.
            </div>
          </div>
        </div>

        <EvidenceDrawer />

        <div className="lab-grid">
          <ReactiveStepper />
          <StylusVolLab />
          <AttestationChecker />
          <AcrossTimeline />
          <BrevisProofStatus />
          <ChainlinkBenchmarkCard />
        </div>
      </main>
    </div>
  );
}
