/**
 * STRATUM frontend root: hash-routes between the landing page (default), the live
 * dashboard (#app), and the deposit panel (#deposit). Hash routing keeps deep links
 * and refreshes working without a router dependency.
 */

import { useEffect, useState } from "react";
import Landing from "./Landing";
import Dashboard from "./Dashboard";
import DepositPage from "./DepositPage";
import PositionsPage from "./PositionsPage";
import LabsPage from "./LabsPage";

type View = "landing" | "app" | "deposit" | "positions" | "labs";

function viewFromHash(): View {
  // Use startsWith so query-bearing hashes (e.g. #deposit?action=withdraw) still route.
  const h = window.location.hash;
  if (h.startsWith("#app")) return "app";
  if (h.startsWith("#deposit")) return "deposit";
  if (h.startsWith("#positions")) return "positions";
  if (h.startsWith("#labs")) return "labs";
  return "landing";
}

export default function App() {
  const [view, setView] = useState<View>(viewFromHash);

  useEffect(() => {
    const onHash = () => setView(viewFromHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const go = (target: View) => {
    window.location.hash = target === "landing" ? "" : target;
    window.scrollTo(0, 0);
  };

  if (view === "app") return <Dashboard onBack={() => go("landing")} onDeposit={() => go("deposit")} />;
  if (view === "deposit") return <DepositPage onBack={() => go("landing")} onDashboard={() => go("app")} />;
  if (view === "positions") return <PositionsPage />;
  if (view === "labs") return <LabsPage />;
  return <Landing onLaunch={() => go("app")} onDeposit={() => go("deposit")} />;
}
