/**
 * STRATUM Demo Frontend -- entry point.
 *
 * Stack: React 18, wagmi v2, viem, TypeScript.
 * Chain: Unichain Sepolia (chain ID 1301).
 *
 * Quick start:
 *   cd frontend
 *   npm install
 *   NEXT_PUBLIC_HOOK_ADDRESS=0x... npm run dev
 */

import React from "react";
import ReactDOM from "react-dom/client";
import { WagmiProvider, createConfig, http } from "wagmi";
import type { CreateConnectorFn } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { injected, walletConnect, coinbaseWallet } from "wagmi/connectors";
import App from "./App";
import { UNICHAIN_SEPOLIA } from "./config/addresses";
import "./styles.css";

// `process.env` is statically replaced at build time by the `define` block in vite.config.ts;
// this declaration just gives TypeScript a type for it (no Node runtime is involved).
declare const process: { env: Record<string, string | undefined> };

const queryClient = new QueryClient();

// WalletConnect needs a project id from https://cloud.reown.com (free). Set it as
// NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID. If unset, we degrade gracefully to injected +
// Coinbase Wallet only, so the demo still connects MetaMask without any cloud signup.
const walletConnectProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "";

const connectors: CreateConnectorFn[] = [
  // Browser-extension wallets (MetaMask, Rabby, Brave, ...). Always available.
  injected({ shimDisconnect: true }),
  // Coinbase Wallet: no project id required.
  coinbaseWallet({ appName: "STRATUM" }),
];

if (walletConnectProjectId) {
  connectors.push(
    walletConnect({
      projectId: walletConnectProjectId,
      showQrModal: true,
      metadata: {
        name: "STRATUM",
        description: "Credit-tranched Uniswap v4 liquidity",
        url: "https://stratum.local",
        icons: [],
      },
    })
  );
}

const wagmiConfig = createConfig({
  chains: [UNICHAIN_SEPOLIA],
  connectors,
  transports: {
    [UNICHAIN_SEPOLIA.id]: http(UNICHAIN_SEPOLIA.rpcUrls.default.http[0]),
  },
});

if (!walletConnectProjectId && typeof console !== "undefined") {
  // Make the degraded state obvious in dev rather than silently hiding the QR option.
  console.info(
    "[STRATUM] WalletConnect disabled: set NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID to enable the QR/mobile connector. Injected + Coinbase Wallet are active."
  );
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <App />
      </QueryClientProvider>
    </WagmiProvider>
  </React.StrictMode>
);
