/**
 * Phase D (D-7): minimal GraphQL client for the STRATUM subgraph.
 *
 * Plain fetch instead of a GraphQL library: the queries are static strings and the responses
 * are small, so a dependency adds nothing but bundle size. Endpoint comes from config; an empty
 * endpoint means "subgraph not configured" and callers must degrade gracefully
 * (FRONTEND_UPGRADE_INSTRUCTIONS 7.5).
 */

import { STRATUM_ADDRESSES } from "../config/addresses";

export function subgraphConfigured(): boolean {
  return !!STRATUM_ADDRESSES.subgraphUrl;
}

export async function subgraphQuery<T>(query: string, variables: Record<string, unknown>): Promise<T> {
  const url = STRATUM_ADDRESSES.subgraphUrl;
  if (!url) throw new Error("Subgraph not configured");

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new Error(`Subgraph HTTP ${res.status}`);

  const json = (await res.json()) as { data?: T; errors?: { message: string }[] };
  if (json.errors?.length) throw new Error(json.errors.map((e) => e.message).join("; "));
  if (!json.data) throw new Error("Subgraph returned no data");
  return json.data;
}
