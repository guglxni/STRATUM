/**
 * Integration status strip (spec §5.3): an at-a-glance row of the full multi-chain stack, so a
 * judge sees Reactive / Across / Stylus / EigenLayer / Brevis / Chainlink without scrolling to the
 * address panel. Each pill links to the real contract on its chain's explorer and carries an honest
 * status (Brevis is "partial") plus the event that triggers it.
 */

import { INTEGRATIONS, STATUS_GLYPH } from "../config/integrationEvidence";
import { explorerAddress, explorerName, shortAddr } from "../config/explorers";

export default function IntegrationStatusStrip() {
  return (
    <div className="int-strip" role="list" aria-label="Integration status">
      <span className="int-strip-label">Full stack</span>
      {INTEGRATIONS.map((it) => {
        const g = STATUS_GLYPH[it.status];
        const hasLink = !!it.address;
        const title = `${it.name} (${g.word}) · triggers: ${it.triggerEvent}\n${it.blurb}${
          hasLink ? `\n${shortAddr(it.address)} on ${explorerName(it.chainId)}` : ""
        }`;
        const body = (
          <>
            <span className={`int-dot int-dot-${it.status}`} aria-hidden>
              {g.dot}
            </span>
            {it.name}
          </>
        );
        return hasLink ? (
          <a
            key={it.id}
            role="listitem"
            className={`int-pill int-pill-${it.status}`}
            href={explorerAddress(it.address, it.chainId)}
            target="_blank"
            rel="noreferrer"
            title={title}
            aria-label={`${it.name}: ${g.word}. ${it.blurb}`}
          >
            {body}
          </a>
        ) : (
          <span
            key={it.id}
            role="listitem"
            className={`int-pill int-pill-${it.status} int-pill-static`}
            title={title}
            aria-label={`${it.name}: ${g.word}. ${it.blurb}`}
          >
            {body}
          </span>
        );
      })}
    </div>
  );
}
