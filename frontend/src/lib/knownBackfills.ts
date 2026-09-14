import { AuditEvent } from "./api";

// The authoritative signal for "was this row caught live or manually
// replayed" is the API's own `source` field (see scripts/backfill_known_event.py
// and event_store.SOURCES in the backend) -- not this file. This file only
// supplies the human-readable real broadcast date for known backfilled tx
// hashes, since that date isn't itself a column in events.db.
export interface KnownBackfill {
  txHash: string;
  broadcastAt: string; // real on-chain broadcast time, not detected_at
}

export const KNOWN_BACKFILLS: KnownBackfill[] = [
  {
    txHash: "0x4ac23f2e58e2c4962dcd701c2beff581e87f3995152a29d527c07a3afd67d956",
    broadcastAt: "2026-09-09T23:50:42Z",
  },
];

export function findBackfill(txHash: string): KnownBackfill | undefined {
  return KNOWN_BACKFILLS.find((b) => b.txHash.toLowerCase() === txHash.toLowerCase());
}

export function isHistoricalBackfill(event: AuditEvent): boolean {
  return event.source === "historical_backfill";
}

function formatBroadcastDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-US", {
    timeZone: "UTC",
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

// Single canonical wording, reused by Screen A/B/C so none of them drift.
export function backfillLabel(event: AuditEvent): string | null {
  if (!isHistoricalBackfill(event)) return null;
  const known = findBackfill(event.tx_hash);
  return known
    ? `Verified from historical broadcast (${formatBroadcastDate(known.broadcastAt)})`
    : "Verified from a historical broadcast";
}
