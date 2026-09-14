"use client";

import { useState } from "react";
import { requestWalletAddress } from "@/lib/ethereum";
import { DEMO_HOLDER_ADDRESS } from "@/lib/tokens";

interface Props {
  value: string;
  onChange: (address: string) => void;
}

export function AddressInput({ value, onChange }: Props) {
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleConnect() {
    setConnecting(true);
    setError(null);
    try {
      const address = await requestWalletAddress();
      onChange(address);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to connect wallet.");
    } finally {
      setConnecting(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-3 sm:flex-row">
        <input
          value={value}
          onChange={(e) => onChange(e.target.value.trim())}
          placeholder="0x… wallet address"
          spellCheck={false}
          className="min-w-0 flex-1 rounded-xl border bg-background-raised px-4 py-3 font-mono text-[13px] text-foreground outline-none transition-colors focus:border-interactive"
          style={{ borderColor: "var(--border-strong)" }}
        />
        <button
          onClick={handleConnect}
          disabled={connecting}
          className="shrink-0 rounded-xl px-5 py-3 text-[13px] font-medium text-background transition-transform active:scale-[0.97] disabled:opacity-60"
          style={{ background: "var(--interactive)" }}
        >
          {connecting ? "Connecting…" : "Connect Wallet"}
        </button>
      </div>
      <div className="flex items-center gap-3 text-[12px] text-foreground-dim">
        {error && <span className="text-red-400">{error}</span>}
        <button
          onClick={() => onChange(DEMO_HOLDER_ADDRESS)}
          className="underline decoration-dotted underline-offset-2 transition-colors hover:text-interactive"
        >
          Try example address (largest known NVDA holder)
        </button>
      </div>
    </div>
  );
}
