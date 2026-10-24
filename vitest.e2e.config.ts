import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// End-to-end against the local stack: `supabase start`, scripts/local-env.sh, local
// clamd (services/scanner: docker compose up -d clamd), scanner built (npm run build).
export default defineConfig({
  test: { include: ["e2e/**/*.e2e.test.ts"], testTimeout: 120_000, hookTimeout: 180_000, fileParallelism: false },
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
      "server-only": fileURLToPath(new URL("./e2e/server-only-stub.ts", import.meta.url)),
    },
  },
});
