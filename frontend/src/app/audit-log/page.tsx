"use client";

import { useEffect, useRef, useState } from "react";
import { NavBar } from "@/components/NavBar";
import { FeedThroughput, Tick } from "@/components/FeedThroughput";
import { AuditLogTable } from "@/components/AuditLogTable";
import { AuditEvent, getAuditLog } from "@/lib/api";
import { downloadAuditLogCsv, downloadAuditLogJson } from "@/lib/download";
import { KNOWN_TOKENS } from "@/lib/tokens";
import { useConsensusConfirmations } from "@/lib/useConsensusConfirmations";

const POLL_INTERVAL_MS = 5000;

export default function AuditLogPage() {
  const [events, setEvents] = useState<AuditEvent[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [ticks, setTicks] = useState<Tick[]>([]);
  const lastCount = useRef<number | null>(null);
  const tickId = useRef(0);

  useEffect(() => {
    let cancelled = false;

    async function poll() {
      try {
        const res = await getAuditLog();
        if (cancelled) return;
        setEvents(res.events);
        setError(null);

        const detected =
          lastCount.current !== null && res.count > lastCount.current;
        lastCount.current = res.count;
        tickId.current += 1;
        setTicks((prev) => [...prev, { id: tickId.current, detected }].slice(-48));
      } catch {
        if (!cancelled) setError("Could not reach the Gapwatch API.");
      }
    }

    poll();
    const id = setInterval(poll, POLL_INTERVAL_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  // Additive layer: the table below renders from V1 regardless.
  const confirmations = useConsensusConfirmations(events);

  const tokensWithHistory = new Set((events ?? []).map((e) => e.token_address.toLowerCase()));
  const tokensWithoutHistory = KNOWN_TOKENS.filter(
    (t) => !tokensWithHistory.has(t.address.toLowerCase())
  );

  return (
    <>
      <NavBar />
      <main className="flex-1 px-6 pt-32 pb-20 md:px-10">
        <div className="mx-auto max-w-3xl">
          <p className="mb-3 text-[11px] font-medium uppercase tracking-[0.16em] text-foreground-muted">
            Screen C
          </p>
          <h1 className="text-[2.2rem] font-semibold tracking-tight text-foreground sm:text-[2.75rem]">
            Audit log
          </h1>
          <p className="mt-3 max-w-xl text-[14px] leading-relaxed text-foreground-muted">
            The complete off-chain detection history — including events that
            were later filtered out, or never made it to L1 confirmation.
            Gapwatch watches the raw sequencer feed, before exclusion happens,
            so a silently-excluded transaction still shows up here.
          </p>

          <div
            className="mt-8 rounded-2xl border p-6"
            style={{
              borderColor: "var(--border-strong)",
              backdropFilter: "blur(20px) saturate(160%)",
              WebkitBackdropFilter: "blur(20px) saturate(160%)",
              background: "rgba(11, 13, 17, 0.7)",
            }}
          >
            <FeedThroughput ticks={ticks} />
          </div>

          <div className="mt-10 flex items-center justify-between gap-4">
            <div className="flex items-center gap-2 text-[12px] text-foreground-dim">
              <span
                className="h-1.5 w-1.5 rounded-full"
                style={{ background: error ? "#f87171" : "var(--semantic-confirmed)" }}
              />
              {error ? error : `Source: SQLite via /audit-log · polled every 5s`}
            </div>
            <div className="flex gap-2">
              <button
                onClick={() => events && downloadAuditLogJson(events)}
                disabled={!events || events.length === 0}
                className="rounded-lg px-3 py-1.5 text-[12px] font-medium text-background transition-transform active:scale-[0.97] disabled:opacity-40"
                style={{ background: "var(--interactive)" }}
              >
                Download JSON
              </button>
              <button
                onClick={() => events && downloadAuditLogCsv(events)}
                disabled={!events || events.length === 0}
                className="rounded-lg border px-3 py-1.5 text-[12px] font-medium text-interactive transition-colors disabled:opacity-40"
                style={{ borderColor: "var(--border-strong)" }}
              >
                Download CSV
              </button>
            </div>
          </div>

          <div
            className="mt-4 overflow-hidden rounded-2xl border px-5"
            style={{ borderColor: "var(--border-soft)" }}
          >
            {events === null && !error ? (
              <p className="py-8 text-[13px] text-foreground-dim">Loading…</p>
            ) : (
              <AuditLogTable
                events={[...(events ?? [])].sort((a, b) => b.id - a.id)}
                confirmations={confirmations}
              />
            )}
          </div>

          {events !== null && (
            <p className="mt-6 text-[12px] leading-relaxed text-foreground-dim">
              {tokensWithHistory.size === 0
                ? "None of the 5 tokens shown on the Balances screen have a detected event yet."
                : `${tokensWithHistory.size} of 5 tokens shown on the Balances screen have real detected events so far (${Array.from(
                    tokensWithHistory
                  )
                    .map((a) => KNOWN_TOKENS.find((t) => t.address.toLowerCase() === a)?.symbol ?? a)
                    .join(", ")}).`}{" "}
              {tokensWithoutHistory.length > 0 &&
                `${tokensWithoutHistory
                  .map((t) => t.symbol)
                  .join(
                    ", "
                  )} show no history here — not filtered out, simply not yet observed by this pipeline.`}
            </p>
          )}
        </div>
      </main>
    </>
  );
}
