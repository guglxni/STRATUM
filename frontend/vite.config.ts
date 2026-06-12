import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

// `config/addresses.ts` and `main.tsx` read overrides via `process.env.NEXT_PUBLIC_*`. Vite does not
// inject `process` into the browser, so map those reads onto the build-time environment here; without
// this define the modules would throw a ReferenceError at startup.
//
// We merge two sources so both work: a `frontend/.env` file (loaded via Vite's loadEnv) and the actual
// shell environment (which takes precedence, so `NEXT_PUBLIC_X=... npm run dev` still overrides the file).
export default defineConfig(({ mode }) => {
  const fileEnv = loadEnv(mode, process.cwd(), "");
  const merged = { ...fileEnv, ...process.env };
  const publicEnv = Object.fromEntries(
    Object.entries(merged).filter(([k]) => k.startsWith("NEXT_PUBLIC_"))
  );

  // Vite's `define` for `process.env.*` is unreliable in the dev server (it special-cases `process.env`
  // and steers you to `import.meta.env`), so the source reads of `process.env.NEXT_PUBLIC_*` are NOT
  // statically replaced and `process` is undefined in the browser. The robust fix that works in BOTH dev
  // and build: inject a real `window.process.env` global into index.html with the public vars baked in.
  // Keep `define` too (it does take effect in production builds and lets bundlers tree-shake).
  const define: Record<string, string> = {
    "process.env": JSON.stringify(publicEnv),
  };
  for (const [key, value] of Object.entries(publicEnv)) {
    define[`process.env.${key}`] = JSON.stringify(value);
  }

  const injectProcessEnv = {
    name: "stratum-inject-process-env",
    transformIndexHtml() {
      return [
        {
          tag: "script",
          // Runs before the module entry. Defines a minimal `process.env` so `process.env.NEXT_PUBLIC_*`
          // reads resolve to the baked values (or undefined -> the code's `?? "fallback"` default).
          children: `window.process = window.process || {}; window.process.env = Object.assign({}, ${JSON.stringify(
            publicEnv
          )}, window.process.env);`,
          injectTo: "head-prepend" as const,
        },
      ];
    },
  };

  return {
    plugins: [react(), injectProcessEnv],
    define,
  };
});
