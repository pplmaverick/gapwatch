import type { NextConfig } from "next";

// The Gapwatch API is plain HTTP (no domain provisioned yet, see
// deployment notes) while the frontend is always served over HTTPS.
// Browsers block a same-page HTTPS->HTTP fetch outright (mixed content),
// so the browser must never see that URL: it only ever calls the
// same-origin, same-protocol path below, and this rewrite -- which runs
// server-side, in both `next dev` and on Vercel -- makes the real HTTP
// request on the browser's behalf.
const nextConfig: NextConfig = {
  async rewrites() {
    return [
      {
        source: "/api/backend/:path*",
        destination: "http://46.62.246.244:8080/:path*",
      },
    ];
  },
};

export default nextConfig;
