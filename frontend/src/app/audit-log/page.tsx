"use client";

import { useEffect, useRef, useState } from "react";
import { NavBar } from "@/components/NavBar";
import { FeedPoll, FeedWaveform } from "@/components/FeedWaveform";
import { AuditLogTable } from "@/components/AuditLogTable";
import { AuditEvent, getAuditLog } from "@/lib/api";
import { downloadAuditLogCsv, downloadAuditLogJson } from "@/lib/download";
import { findKnownToken } from "@/lib/tokens";
import { isHistoricalBackfill } from "@/lib/knownBackfills";
import { useConsensusConfirmations } from "@/lib/useConsensusConfirmations";

const POLL_INTERVAL_MS = 5000;
/** Enough polls to cover the waveform's 60s window with headroom. */
const POLL_HISTORY = 24;

function shortAddress(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export default function AuditLogPage() {
  const [events, setEvents] = useState<AuditEvent[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [polls, setPolls] = useState<FeedPoll[]>([]);
  /**
   * Event ids already seen. `null` until the first response lands: everything
   * in that first payload is pre-existing history, not something detected
   * while the page was open, so it must not spike the waveform.
   */
  const seenIds = useRef<Set<number> | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function poll() {
      try {
        const res = await getAuditLog();
        if (cancelled) return;
        setEvents(res.events);
        setError(null);

        // Diff by event id rather than by count: a count can stay level while
        // rows change, and the id tells us which token to label the spike with.
        const at = Date.now();
        let detections: FeedPoll["detections"] = [];
        if (seenIds.current === null) {
          seenIds.current = new Set(res.events.map((e) => e.id));
        } else {
          const seen = seenIds.current;
          detections = res.events
            .filter((e) => !seen.has(e.id))
            .map((e) => ({
              eventId: e.id,
              token: findKnownToken(e.token_address)?.symbol ?? shortAddress(e.token_address),
              at,
            }));
          for (const e of res.events) seen.add(e.id);
        }
        setPolls((prev) => [...prev, { at, detections }].slice(-POLL_HISTORY));
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

  // Every row in the table below already has a real detected event by
  // definition, so "how many of the shown tokens have events" is a
  // tautology on this page (unlike on the Balances screen, which is scoped
  // to a fixed 5-token list and can meaningfully ask that). What's actually
  // informative here is the live/historical split, using the same `source`
  // field the SOURCE column itself renders from (via `isHistoricalBackfill`)
  // so this can never drift from what the table shows.
  const liveCount = (events ?? []).filter((e) => !isHistoricalBackfill(e)).length;
  const historicalCount = (events ?? []).length - liveCount;

  return (
    <>
      <NavBar />
      <main className="flex-1 px-6 pt-32 pb-20 md:px-10">
        <div className="mx-auto max-w-3xl">
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
            <FeedWaveform polls={polls} />
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

          {events !== null && events.length > 0 && (
            <p className="mt-6 text-[12px] leading-relaxed text-foreground-dim">
              {liveCount === 0
                ? `All ${historicalCount} event${historicalCount === 1 ? "" : "s"} shown here were confirmed by replaying a historical broadcast — none caught live yet.`
                : historicalCount === 0
                  ? `All ${liveCount} event${liveCount === 1 ? "" : "s"} shown here were caught live, straight off the sequencer feed.`
                  : `${liveCount} of ${events.length} events shown here were caught live, straight off the sequencer feed. The remaining ${historicalCount} were confirmed by replaying a historical broadcast.`}
            </p>
          )}
        </div>
      </main>
    </>
  );
}
