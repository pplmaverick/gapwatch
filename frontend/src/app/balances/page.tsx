"use client";

import { useEffect, useMemo, useState } from "react";
import { NavBar } from "@/components/NavBar";
import { AddressInput } from "@/components/AddressInput";
import { TokenRow } from "@/components/TokenRow";
import { AuditEvent, getAuditLog, getKnownTokens, KnownTokenEntry } from "@/lib/api";
import { useConsensusConfirmations } from "@/lib/useConsensusConfirmations";

function tokenLabel(t: KnownTokenEntry) {
  return t.symbol ?? t.address;
}

function sortTokens(tokens: KnownTokenEntry[]) {
  return [...tokens].sort((a, b) => tokenLabel(a).localeCompare(tokenLabel(b)));
}

export default function BalancesPage() {
  const [holderAddress, setHolderAddress] = useState("");
  const [auditLog, setAuditLog] = useState<AuditEvent[]>([]);
  const [tokens, setTokens] = useState<KnownTokenEntry[] | null>(null);
  const [tokensFailed, setTokensFailed] = useState(false);
  const [showAll, setShowAll] = useState(false);

  useEffect(() => {
    getAuditLog()
      .then((res) => setAuditLog(res.events))
      .catch(() => setAuditLog([]));
  }, []);

  useEffect(() => {
    getKnownTokens()
      .then((res) => setTokens(res.tokens))
      .catch(() => {
        setTokens([]);
        setTokensFailed(true);
      });
  }, []);

  // Additive layer: balances and history below come from V1 either way.
  const confirmations = useConsensusConfirmations(auditLog);

  // The full factory-discovered registry (~200 tokens), not a hardcoded
  // shortlist. Tokens with a real detected event are shown expanded and
  // fetch their balance immediately, same as before; the rest are collapsed
  // by default and, once revealed, fetch lazily as each row scrolls into
  // view (see TokenRow's `eager` prop) rather than all firing an RPC call
  // at once.
  const detectedTokens = useMemo(
    () => sortTokens((tokens ?? []).filter((t) => t.has_detected_event)),
    [tokens]
  );
  const undetectedTokens = useMemo(
    () => sortTokens((tokens ?? []).filter((t) => !t.has_detected_event)),
    [tokens]
  );

  function matchedEventsFor(address: string) {
    return auditLog.filter(
      (e) => e.token_address.toLowerCase() === address.toLowerCase()
    );
  }

  return (
    <>
      <NavBar />
      <main className="flex-1 px-6 pt-32 pb-20 md:px-10">
        <div className="mx-auto max-w-3xl">
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
            {tokens === null ? (
              <p className="px-5 py-8 text-[13px] text-foreground-dim">
                Loading tokens…
              </p>
            ) : (
              detectedTokens.map((token) => (
                <TokenRow
                  key={token.address}
                  token={token}
                  holderAddress={holderAddress}
                  matchedEvents={matchedEventsFor(token.address)}
                  confirmations={confirmations}
                  eager
                />
              ))
            )}
          </div>

          {tokens !== null && undetectedTokens.length > 0 && (
            <div className="mt-4">
              <button
                onClick={() => setShowAll((v) => !v)}
                className="text-[12px] font-medium text-interactive"
              >
                {showAll ? "Hide" : "Show"} {undetectedTokens.length} more token
                {undetectedTokens.length === 1 ? "" : "s"} — no detected event
                yet
              </button>

              {showAll && (
                <div
                  className="mt-3 overflow-hidden rounded-2xl border"
                  style={{
                    borderColor: "var(--border-soft)",
                    background: "rgba(11, 13, 17, 0.4)",
                  }}
                >
                  {undetectedTokens.map((token) => (
                    <TokenRow
                      key={token.address}
                      token={token}
                      holderAddress={holderAddress}
                      matchedEvents={[]}
                      confirmations={confirmations}
                      eager={false}
                    />
                  ))}
                </div>
              )}
            </div>
          )}

          {tokens !== null && (
            <p className="mt-6 text-[12px] leading-relaxed text-foreground-dim">
              {tokensFailed
                ? "Could not load the token registry."
                : `${detectedTokens.length} of ${tokens.length} known tokens have a detected event; showing those first.`}
            </p>
          )}
        </div>
      </main>
    </>
  );
}
