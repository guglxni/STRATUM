#!/usr/bin/env python3
"""Author the STRATUM diagram set as draw.io files. Run, then render with draw.io CLI."""
import os
from drawio_gen import Diagram

OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "diagrams", "drawio")
os.makedirs(OUT, exist_ok=True)


def save(d, fname):
    d.save(os.path.join(OUT, fname))
    print("wrote", fname)


# ─────────────────────────────────────────────────────────────────────────────
# 1. System architecture — core / reactive / peripherals (replaces system-layers)
# ─────────────────────────────────────────────────────────────────────────────
def system_architecture():
    d = Diagram("stratum-architecture", width=1320, height=940)
    # Core band (bottom-center)
    d.band(360, 600, 600, 300, "①  Unichain Sepolia — core hook (always on)", "core")
    pm = d.node(400, 670, 200, 64, "PoolManager v4\n(canonical Uniswap v4)", "soft")
    hk = d.node(720, 670, 200, 64, "StratumHook\ncore tranche logic", "core", node_id="hk")
    st = d.node(420, 790, 150, 56, "stLP\nsenior receipt", "senior")
    jt = d.node(750, 790, 150, 56, "jtLP\njunior receipt", "junior")
    d.edge(pm, hk, "hooks", style="thick")
    d.edge(hk, st, "")
    d.edge(hk, jt, "")

    # Reactive band (top-left)
    d.band(60, 60, 560, 260, "②  Reactive Network — autonomic coordination (Lasna 5318007)", "reactive")
    es = d.node(100, 140, 150, 56, "EpochSettler\nFR-15", "reactive")
    cm = d.node(280, 140, 150, 56, "CoverageMonitor\nFR-16", "reactive")
    rb = d.node(460, 140, 130, 56, "ReserveBalancer\nFR-17", "reactive")
    d.node(100, 230, 490, 56, "subscribe hook event logs (topic_0)  →  react()  →  schedule callback", "soft")

    # Peripherals band (top-right)
    per = d.band(700, 60, 560, 260, "③  Optional peripherals — behind IPeripheral", "peripheral")
    d.node(730, 140, 120, 70, "Across\nCPHR\ncross-chain reserve", "junior", dashed=True)
    d.node(870, 140, 120, 70, "Brevis\nZK fee\nattribution", "junior", dashed=True)
    d.node(1010, 140, 120, 70, "EigenLayer\nAVS\nLVR yield", "junior", dashed=True)
    d.node(1150, 140, 90, 70, "Stylus\nmatch +\nML vol", "junior", dashed=True)
    d.node(730, 235, 510, 50, "Chainlink benchmark · correlation registry · intents — each optional, core unaware", "soft", fontsize=13)

    # One clean connector per layer into the hook (avoids label clutter)
    d.edge(es, hk, "epoch / stress\ncallbacks", style="thick", color="#5A2D6E",
           exitX=(0.5, 1), entryX=(0.5, 0))
    d.edge(per, hk, "reserve bridge · proof verify · LVR yield · vol / netting",
           style="dashed", color="#2D6A4A", exitX=(0.5, 1), entryX=(1, 0.3),
           points=[(980, 470), (920, 702)])

    d.note(360, 906, 600, 24,
           "Golden rule: the core compiles and passes tests with every peripheral disabled (NFR-01).")
    save(d, "stratum-architecture.drawio")


# ─────────────────────────────────────────────────────────────────────────────
# 2. Fee waterfall (replaces fee-waterfall)
# ─────────────────────────────────────────────────────────────────────────────
def fee_waterfall():
    d = Diagram("fee-waterfall", width=900, height=1180)
    cx = 350
    s = d.node(cx, 40, 200, 56, "Swap volume", "core")
    f = d.node(cx, 140, 200, 56, "beforeSwap\ndynamic fee (bps)", "core")
    a = d.node(cx, 240, 200, 56, "afterSwap\nfeeAmount", "core")
    w = d.node(cx, 340, 200, 56, "Waterfall.splitFee", "core")

    p = d.node(90, 460, 180, 64, "protocolPortion", "protocol")
    sn = d.node(330, 460, 230, 64, "seniorPortion →\nepochSeniorFunded", "senior")
    ju = d.node(620, 460, 200, 64, "juniorPortion →\njuniorReserve", "junior")

    ce = d.node(cx, 600, 200, 56, "closeEpoch", "core")

    sf = d.node(70, 720, 220, 64, "seniorFeePerShareX128", "senior")
    jf = d.node(330, 720, 220, 64, "juniorFeePerShareX128", "junior")
    sh = d.node(610, 720, 220, 64, "shortfall →\ndraw juniorReserve", "junior")

    se = d.node(110, 860, 180, 64, "settleSenior\nearned (smoothed)", "senior")
    je = d.node(360, 860, 180, 64, "settleJunior\nearned (smoothed)", "junior")

    d.edge(s, f); d.edge(f, a); d.edge(a, w)
    d.edge(w, p); d.edge(w, sn, "", color="#1A4A8A"); d.edge(w, ju, "", color="#2D6A4A")
    d.edge(sn, ce, "", color="#1A4A8A"); d.edge(ju, ce, "", color="#2D6A4A")
    d.edge(ce, sf, "senior obligation\nfunded first", color="#1A4A8A")
    d.edge(ce, jf, "surplus to junior", color="#2D6A4A")
    d.edge(ce, sh, "", color="#2D6A4A")
    d.edge(sf, se, "", color="#1A4A8A"); d.edge(jf, je, "", color="#2D6A4A")
    d.note(70, 1000, 760, 60,
           "Senior is paid its fixed coupon from the epoch accumulator before junior takes the surplus "
           "(INV-04). On shortfall, the junior buffer is drawn to make senior whole; the epoch counter "
           "advances (INV-06). No oracle anywhere on this path.")
    save(d, "fee-waterfall.drawio")


# ─────────────────────────────────────────────────────────────────────────────
# 3. Reactive flow (replaces reactive-flow)
# ─────────────────────────────────────────────────────────────────────────────
def reactive_flow():
    d = Diagram("reactive-flow", width=1280, height=660)
    # Reactive band (top)
    d.band(360, 40, 560, 210, "Reactive Lasna — chain 5318007", "reactive")
    rsc = d.node(400, 120, 480, 100,
                 "EpochSettler · CoverageMonitor · ReserveBalancer\nreact(LogRecord)\n"
                 "enforce monotonic nonce, schedule callback", "reactive")

    # Origin band (bottom)
    d.band(60, 340, 1160, 280, "Unichain Sepolia — origin chain (1301)", "core")
    hook = d.node(100, 420, 220, 120,
                  "StratumHook\nemits EpochClosed /\nCoverageStress /\nJuniorReserveUpdated", "soft")
    proxy = d.node(640, 420, 230, 100,
                   "reactiveCallback(poolId)\nvia callback proxy\n(no off-chain keeper)", "soft")
    effect = d.node(960, 420, 220, 100,
                    "closeEpoch settlement /\nCPHR rebalance signal", "soft")
    d.edge(proxy, effect, "", color="#1A3A5C")

    # 1: hook → rsc, routed up the left side so the label clears the proxy box
    d.edge(hook, rsc, "1 — event log,\nsubscribed topic_0", style="thick", color="#5A2D6E",
           exitX=(0.5, 0), entryX=(0.12, 1), points=[(210, 300)])
    # 2: rsc → proxy, straight down the centre
    d.edge(rsc, proxy, "2 — emit Callback,\nschedule call", style="thick", color="#5A2D6E",
           exitX=(0.55, 1), entryX=(0.5, 0))
    # return: effect → hook, routed along the bottom margin, clear of the boxes
    d.edge(effect, hook, "next epoch / next stress event", style="dashed", color="#52606D",
           exitX=(0.5, 1), entryX=(0.5, 1), points=[(1070, 588), (210, 588)])
    d.note(60, 628, 1160, 24,
           "One closed loop, fully on-chain: a hook event on Unichain is caught on Lasna and a callback is "
           "scheduled back to Unichain — no bot, no cron.")
    save(d, "reactive-flow.drawio")


# ─────────────────────────────────────────────────────────────────────────────
# 4. Tranche lifecycle (NEW) — deposit → accrue → settle
# ─────────────────────────────────────────────────────────────────────────────
def tranche_lifecycle():
    d = Diagram("tranche-lifecycle", width=1340, height=560)
    dep = d.node(40, 230, 180, 90, "LP deposits\nvia StratumZap\nchooses tranche", "soft")
    # Senior lane
    d.band(280, 40, 1020, 220, "Senior  (stLP) — fixed, IL-protected", "core")
    s1 = d.node(320, 120, 200, 80, "Coverage floor check\nINV-01 enforced", "senior")
    s2 = d.node(560, 120, 200, 80, "Accrue fixed coupon\nepoch-smoothed", "senior")
    s3 = d.node(800, 120, 200, 80, "Junior buffer absorbs IL\nsenior protected", "senior")
    s4 = d.node(1040, 120, 220, 80, "Withdraw: principal\n+ vested coupon", "senior")
    d.edge(s1, s2, "", color="#1A4A8A"); d.edge(s2, s3, "", color="#1A4A8A"); d.edge(s3, s4, "", color="#1A4A8A")
    # Junior lane
    d.band(280, 300, 1020, 220, "Junior  (jtLP) — leveraged fees, first-loss", "junior")
    j1 = d.node(320, 380, 200, 80, "Deposit funds\njunior buffer", "junior")
    j2 = d.node(560, 380, 200, 80, "Earn fee surplus\nafter senior funded", "junior")
    j3 = d.node(800, 380, 200, 80, "Absorb IL first\ndollar-for-dollar", "junior")
    j4 = d.node(1040, 380, 220, 80, "Withdraw: principal\n+ surplus − IL", "junior")
    d.edge(j1, j2, "", color="#2D6A4A"); d.edge(j2, j3, "", color="#2D6A4A"); d.edge(j3, j4, "", color="#2D6A4A")
    d.edge(dep, s1, "senior", color="#1A4A8A", exitX=(1, 0.5), entryX=(0, 0.5), points=[(270, 160)])
    d.edge(dep, j1, "junior", color="#2D6A4A", exitX=(1, 0.5), entryX=(0, 0.5), points=[(270, 420)])
    save(d, "tranche-lifecycle.drawio")


# ─────────────────────────────────────────────────────────────────────────────
# 5. IL absorption waterfall (NEW)
# ─────────────────────────────────────────────────────────────────────────────
def il_waterfall():
    d = Diagram("il-absorption", width=900, height=720)
    il = d.node(330, 40, 240, 64, "Impermanent loss realized\n(from tick deltas, no oracle)", "core")
    q1 = d.node(330, 160, 240, 70, "Junior buffer\n≥ IL ?", "warn")
    a1 = d.node(60, 300, 260, 80, "YES — junior buffer absorbs\nfull IL; senior untouched", "junior")
    a2 = d.node(560, 300, 280, 80, "NO — buffer drained to 0,\nshortfall remains", "junior")
    cap = d.node(560, 430, 280, 80, "Senior absorbs shortfall up to\nmaxSeniorILExposureBps cap", "senior")
    res = d.node(560, 560, 280, 80, "Beyond cap: realized loss\n(documented worst case)", "protocol")
    d.edge(il, q1)
    d.edge(q1, a1, "buffer covers it", color="#2D6A4A", exitX=(0.15, 1))
    d.edge(q1, a2, "buffer short", color="#9A6A14", exitX=(0.85, 1))
    d.edge(a2, cap, "", color="#1A4A8A")
    d.edge(cap, res, "", color="#6E6E73")
    d.note(60, 430, 420, 120,
           "The junior buffer is the only thing between a volatile market and senior principal. "
           "Any code path that can reduce it is reviewed against the coverage-ratio invariant before "
           "merge (golden rule 3).")
    save(d, "il-absorption.drawio")


# ─────────────────────────────────────────────────────────────────────────────
# 6. Cross-chain topology (NEW) — what lives on each chain
# ─────────────────────────────────────────────────────────────────────────────
def cross_chain():
    d = Diagram("cross-chain-topology", width=1340, height=720)
    d.band(40, 60, 620, 280, "Unichain Sepolia (1301) — core + most peripherals", "chainA")
    d.node(70, 140, 170, 56, "StratumHook\n+ tranches", "core")
    d.node(260, 140, 160, 56, "StratumZap\n+ Lens", "soft")
    d.node(440, 140, 190, 56, "CPHR · MatchAttestation\nLVRAuctionReceiver", "soft")
    d.node(70, 230, 170, 56, "BrevisVerifierShim", "soft")
    d.node(260, 230, 160, 56, "StylusShim", "soft")
    d.node(440, 230, 190, 56, "Reactive twins\n(EpochSettler …)", "soft")

    d.band(720, 60, 580, 130, "Reactive Lasna (5318007) — coordination", "chainC")
    d.node(750, 110, 510, 56, "EpochSettler · CoverageMonitor · ReserveBalancer  (subscribed RSCs)", "reactive")

    d.band(720, 230, 280, 110, "Arbitrum Sepolia (421614)", "chainB")
    d.node(750, 280, 220, 44, "Stylus engine\nmatch + ML volatility", "junior")

    d.band(1020, 230, 280, 110, "Ethereum Sepolia (11155111)", "chainD")
    d.node(1050, 280, 220, 44, "Across dest + Chainlink feed", "warn")

    # relations
    d.note(40, 380, 1260, 80,
           "Reactive RSCs subscribe to Unichain hook events and schedule callbacks to the Unichain twins "
           "(callback proxy). StylusShim cross-calls the Arbitrum engine. CPHR bridges junior reserve to "
           "Ethereum Sepolia over Across V3 (deposit 6099 → relayer fill → 0.9995 WETH credited). Chainlink "
           "ETH/USD on Ethereum Sepolia benchmarks the senior target rate only — never the IL path.")
    save(d, "cross-chain-topology.drawio")


# ─────────────────────────────────────────────────────────────────────────────
# 7. Settlement decision tree (NEW)
# ─────────────────────────────────────────────────────────────────────────────
def settlement_tree():
    d = Diagram("settlement-decision", width=1180, height=760)
    w = d.node(480, 40, 240, 64, "Withdraw position\n(afterRemoveLiquidity)", "core")
    t = d.node(480, 150, 240, 64, "Which tranche?", "warn")
    # senior
    sH = d.node(120, 280, 260, 70, "SENIOR\nharvest + vest earnings", "senior")
    s1 = d.node(120, 390, 260, 64, "Charge IL to junior buffer", "senior")
    s2 = d.node(120, 490, 260, 64, "Buffer short? senior IL\ncapped at maxSeniorILExposureBps", "senior")
    s3 = d.node(120, 590, 260, 64, "Pay max(funded, contractual)\ncoupon, once", "senior")
    d.edge(sH, s1, "", color="#1A4A8A"); d.edge(s1, s2, "", color="#1A4A8A"); d.edge(s2, s3, "", color="#1A4A8A")
    # junior
    jH = d.node(800, 280, 260, 70, "JUNIOR\nharvest + vest earnings", "junior")
    j1 = d.node(800, 390, 260, 64, "IL = max(exit, anchor)\n(R2-01 self-sandwich guard)", "junior")
    j2 = d.node(800, 490, 260, 64, "Absorb IL vs principal + fees", "junior")
    j3 = d.node(800, 590, 260, 64, "Pay principal + surplus − IL\n(floored at 0)", "junior")
    d.edge(jH, j1, "", color="#2D6A4A"); d.edge(j1, j2, "", color="#2D6A4A"); d.edge(j2, j3, "", color="#2D6A4A")
    d.edge(w, t)
    d.edge(t, sH, "senior", color="#1A4A8A", exitX=(0.2, 1))
    d.edge(t, jH, "junior", color="#2D6A4A", exitX=(0.8, 1))
    d.note(120, 680, 940, 50,
           "Every settlement path is conservation-checked: total out never exceeds total in plus accrued "
           "fees (INV-03). Forfeited unvested fees return to the junior buffer (FR-14).")
    save(d, "settlement-decision.drawio")


# ─────────────────────────────────────────────────────────────────────────────
# 8. Coverage ratio / stress (NEW)
# ─────────────────────────────────────────────────────────────────────────────
def coverage_ratio():
    d = Diagram("coverage-ratio", width=1180, height=560)
    r = d.node(60, 230, 230, 80, "coverageRatioBps =\njuniorTVL / seniorTVL", "core")
    q = d.node(360, 230, 200, 80, "ratio ≥ floor\n(minCoverageRatioBps) ?", "warn")
    ok = d.node(640, 110, 240, 70, "Healthy — senior intake\nallowed, base fee", "ok")
    stress = d.node(640, 250, 240, 70, "Stressed — block new senior,\nraise dynamic fee", "warn")
    rsc = d.node(640, 390, 240, 70, "CoverageStress event →\nReactive CoverageMonitor", "reactive")
    bal = d.node(940, 250, 200, 70, "ReserveBalancer /\nCPHR top-up", "junior")
    d.edge(r, q)
    d.edge(q, ok, "yes", color="#1F7A4D", exitX=(0.65, 0), entryX=(0.3, 1), points=[(490, 150)])
    d.edge(q, stress, "no", color="#9A6A14", exitX=(1, 0.5), entryX=(0, 0.5))
    d.edge(stress, rsc, "", color="#5A2D6E")
    d.edge(rsc, bal, "", color="#2D6A4A")
    d.note(60, 380, 520, 90,
           "INV-01: the junior/senior coverage floor is enforced at every senior deposit. Stress is a "
           "graduated scalar (slope, not cliff) that both defends the pool on-chain via fees and signals "
           "the Reactive layer to rebalance reserve.")
    save(d, "coverage-ratio.drawio")


if __name__ == "__main__":
    system_architecture()
    fee_waterfall()
    reactive_flow()
    tranche_lifecycle()
    il_waterfall()
    cross_chain()
    settlement_tree()
    coverage_ratio()
    print("done")
