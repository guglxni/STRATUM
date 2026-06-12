/**
 * #positions route: the connected wallet's open zap positions with live lens health and the
 * user-owned writes (claim vested, withdraw). See PositionsPanel for the data path.
 */

import PageNav from "./components/PageNav";
import PositionsPanel from "./components/PositionsPanel";

export default function PositionsPage() {
  return (
    <div className="page-parchment">
      <PageNav active="positions" />
      <main className="dash-main container">
        <PositionsPanel />
      </main>
    </div>
  );
}
