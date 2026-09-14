"use client";

import { useEffect, useState } from "react";
import { NavBar } from "@/components/NavBar";
import { AddressInput } from "@/components/AddressInput";
import { TokenRow } from "@/components/TokenRow";
import { AuditEvent, getAuditLog } from "@/lib/api";
import { KNOWN_TOKENS } from "@/lib/tokens";

export default function BalancesPage() {
  const [holderAddress, setHolderAddress] = useState("");
  const [auditLog, setAuditLog] = useState<AuditEvent[]>([]);

  useEffect(() => {
    getAuditLog()
      .then((res) => setAuditLog(res.events))
      .catch(() => setAuditLog([]));
  }, []);

  return (
    <>
      <NavBar />
      <main className="flex-1 px-6 pt-32 pb-20 md:px-10">
        <div className="mx-auto max-w-3xl">
          <p className="mb-3 text-[11px] font-medium uppercase tracking-[0.16em] text-foreground-muted">
            Screen A
          </p>
          <h1 className="text-[2.2rem] font-semibold tracking-tight text-foreground sm:text-[2.75rem]">
            Balance lookup
          </h1>
          <p className="mt-3 max-w-lg text-[14px] leading-relaxed text-foreground-muted">
            UI-scaled balances, read live from each token contract on
            Robinhood Chain mainnet — never from a database. Expand a row for
            its independently-verified multiplier change history.
          </p>

          <div className="mt-10">
            <AddressInput value={holderAddress} onChange={setHolderAddress} />
          </div>

          <div
            className="mt-8 overflow-hidden rounded-2xl border"
            style={{
              borderColor: "var(--border-strong)",
              backdropFilter: "blur(20px) saturate(160%)",
              WebkitBackdropFilter: "blur(20px) saturate(160%)",
              background: "rgba(11, 13, 17, 0.6)",
            }}
          >
            {KNOWN_TOKENS.map((token) => (
              <TokenRow
                key={token.address}
                token={token}
                holderAddress={holderAddress}
                matchedEvents={auditLog.filter(
                  (e) => e.token_address.toLowerCase() === token.address.toLowerCase()
                )}
              />
            ))}
          </div>

          <p className="mt-6 text-[12px] leading-relaxed text-foreground-dim">
            5 of 22 known tokens shown (discovered via live{" "}
            <code>UIMultiplierUpdated</code> scan). Zero balances are shown,
            not hidden — a real holder can hold zero of most of these.
          </p>
        </div>
      </main>
    </>
  );
}
