// Discovered live via `UIMultiplierUpdated` topic0 eth_getLogs scan against
// Robinhood Chain mainnet (src/token_registry.py), 22 addresses total as of
// 2026-09-14. Symbol/name read directly from each token's on-chain
// symbol()/name(). This subset of 5 is the pair the pipeline has actually
// verified discrepancies for (NVDA — the only token with a real detected
// multiplier event so far) plus the four tokens named in the "announcement
// vs. actual" narrative writeup (MSFT/XOM/AMAT/LLY).
export interface KnownToken {
  symbol: string;
  name: string;
  address: string;
}

export const DEMO_HOLDER_ADDRESS = "0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3";

export const KNOWN_TOKENS: KnownToken[] = [
  {
    symbol: "NVDA",
    name: "NVIDIA",
    address: "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec",
  },
  {
    symbol: "MSFT",
    name: "Microsoft",
    address: "0xe93237c50d904957cf27e7b1133b510c669c2e74",
  },
  {
    symbol: "XOM",
    name: "ExxonMobil Holdings Corporation",
    address: "0xf9b46d3d1b22199d4d1025a9cedb540a33f1a2d5",
  },
  {
    symbol: "AMAT",
    name: "Applied Materials",
    address: "0x36046893810a7e7fce501229d57dc3fc8c8716d0",
  },
  {
    symbol: "LLY",
    name: "Eli Lilly",
    address: "0x8005d266423c7ea827372c9c864491e5786600ea",
  },
];
