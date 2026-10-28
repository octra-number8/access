import type { NextConfig } from "next";

const config: NextConfig = {
  experimental: {
    // Uploads are up to 20 MB (P2-6); leave headroom for the form encoding.
    serverActions: { bodySizeLimit: "21mb" },
  },
  poweredByHeader: false,
  // The PDF font for permit packs (8c-2), read at run time by the job tick and the permit page's
  // "make the pack now" action.
  outputFileTracingIncludes: {
    "/api/jobs/tick": ["./assets/fonts/**"],
    "/permits/**": ["./assets/fonts/**"],
  },
  async headers() {
    return [{
      source: "/:path*",
      headers: [
        { key: "X-Content-Type-Options", value: "nosniff" },
        { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
        { key: "X-Frame-Options", value: "DENY" },
      ],
    }];
  },
};

export default config;
