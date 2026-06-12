/**
 * Add (or switch to) the primary STRATUM chain in an injected wallet via EIP-3085
 * wallet_addEthereumChain. Derives every field from the env-driven UNICHAIN_SEPOLIA config so a
 * different deployment target adds the right network with no code change (spec §5.6).
 */

import { UNICHAIN_SEPOLIA } from "../config/addresses";

interface Eip1193 {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
}

export async function addUnichainChain(): Promise<void> {
  const eth = (window as unknown as { ethereum?: Eip1193 }).ethereum;
  if (!eth?.request) throw new Error("No injected wallet (MetaMask/Rabby) detected in this browser.");

  await eth.request({
    method: "wallet_addEthereumChain",
    params: [
      {
        chainId: "0x" + UNICHAIN_SEPOLIA.id.toString(16),
        chainName: UNICHAIN_SEPOLIA.name,
        nativeCurrency: UNICHAIN_SEPOLIA.nativeCurrency,
        rpcUrls: UNICHAIN_SEPOLIA.rpcUrls.default.http,
        blockExplorerUrls: [UNICHAIN_SEPOLIA.blockExplorers.default.url],
      },
    ],
  });
}
