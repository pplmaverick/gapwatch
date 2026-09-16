"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence } from "motion/react";
import { NavBar } from "@/components/NavBar";
import { EventCard } from "@/components/EventCard";
import { AuditEvent, getEvents } from "@/lib/api";
import { useConsensusConfirmations } from "@/lib/useConsensusConfirmations";

const POLL_INTERVAL_MS = 5000;
const NON_TERMINAL: AuditEvent["status"][] = [
  "pending",
  "filter_check_in_progress",
];

export default function FeedPage() {
  const [events, setEvents] = useState<AuditEvent[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const pollCount = useRef(0);

  useEffect(() => {
    let cancelled = false;

    async function poll() {
      try {
        const res = await getEvents(50, 0);
        if (!cancelled) {
          setEvents(res.events);
          setError(null);
          pollCount.current += 1;
        }
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

  // Additive layer: V1 data above renders regardless of how this resolves.
  const confirmations = useConsensusConfirmations(events);

  const sorted = events ? [...events].sort((a, b) => b.id - a.id) : [];
  const inProgress = sorted.find((e) => NON_TERMINAL.includes(e.status));
  const focalId = inProgress ? inProgress.id : sorted[0]?.id;

  return (
    <>
      <NavBar />
      <main className="flex-1 px-6 pt-32 pb-20 md:px-10">
        <div className="mx-auto max-w-2xl">
          <p className="mb-3 text-[11px] font-medium uppercase tracking-[0.16em] text-foreground-muted">
            Screen B
          </p>
          <h1 className="text-[2.2rem] font-semibold tracking-tight text-foreground sm:text-[2.75rem]">
            Live event monitor
          </h1>
          <p className="mt-3 max-w-lg text-[14px] leading-relaxed text-foreground-muted">
            Every candidate <code>updateMultiplier()</code> call this pipeline
            has verified — whether caught live off the sequencer feed or
            confirmed by manually replaying a known historical broadcast —
            tracked through the off-chain state machine. Pending on-chain
            confirmation, not a substitute for it.
          </p>

          <div className="mt-6 flex items-center gap-2 text-[12px] text-foreground-dim">
            <span
              className="h-1.5 w-1.5 rounded-full"
              style={{ background: error ? "#f87171" : "var(--semantic-confirmed)" }}
            />
            {error ? error : `Source: SQLite via /events · polled every 5s`}
          </div>

          <div className="mt-8 flex flex-col gap-4">
            {events === null && !error && (
              <p className="text-[13px] text-foreground-dim">Loading…</p>
            )}
            {events !== null && sorted.length === 0 && (
              <p className="text-[13px] text-foreground-dim">
                No candidate events detected yet.
              </p>
            )}
            <AnimatePresence initial={false}>
              {sorted.map((event) => (
                <EventCard
                  key={event.id}
                  event={event}
                  focal={event.id === focalId}
                  consensusConfirmed={confirmations.has(event.tx_hash.toLowerCase())}
                />
              ))}
            </AnimatePresence>
          </div>
        </div>
      </main>
    </>
  );
}
