"use client";

import { motion } from "motion/react";
import { AuditEvent } from "@/lib/api";
import { findKnownToken } from "@/lib/tokens";
import { backfillLabel } from "@/lib/knownBackfills";
import { PipelineStatusBar } from "./PipelineStatusBar";
import { ConsensusBadge } from "./ConsensusBadge";

function shortAddress(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

interface Props {
  event: AuditEvent;
  focal: boolean;
  /** True once the mainnet consensus registry holds a record for this event. */
  consensusConfirmed?: boolean;
}

export function EventCard({ event, focal, consensusConfirmed }: Props) {
  // Priority: KNOWN_TOKENS (the Balances screen's curated few), then the
  // factory-discovered registry's symbol/name from the API response (covers
  // every other token the pipeline has seen), then the raw address.
  const known = findKnownToken(event.token_address);
  const symbol = known?.symbol ?? event.symbol;
  const name = known?.name ?? event.name;
  const backfillText = backfillLabel(event);

  return (
    <motion.div
      layout
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ type: "spring", damping: 1, duration: 0.45 }}
      className="rounded-2xl"
      style={{
        border: `1px solid ${focal ? "var(--border-strong)" : "var(--border-soft)"}`,
        background: focal ? "rgba(11, 13, 17, 0.7)" : "rgba(11, 13, 17, 0.35)",
        backdropFilter: focal ? "blur(20px) saturate(160%)" : "none",
        WebkitBackdropFilter: focal ? "blur(20px) saturate(160%)" : "none",
        padding: focal ? "24px" : "16px 20px",
        opacity: focal ? 1 : 0.72,
      }}
    >
      <div
        className={`mb-4 flex flex-wrap items-baseline gap-x-3 gap-y-1 ${
          focal ? "text-[15px]" : "text-[13px]"
        }`}
      >
        <span
          className="font-semibold tracking-tight"
          style={{ color: focal ? "var(--foreground)" : "var(--foreground-muted)" }}
        >
          {symbol ?? shortAddress(event.token_address)}
        </span>
        {name && (
          <span className="text-[12px] text-foreground-dim">{name}</span>
        )}
        <span className="font-mono text-[11px] text-foreground-dim">
          {shortAddress(event.tx_hash)}
        </span>
        <span className="text-[11px] text-foreground-dim">
          block {event.block_number}
        </span>
        {focal && (
          <span
            className="ml-auto rounded-full border px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-foreground-muted"
            style={{ borderColor: "var(--border-strong)" }}
          >
            most recent
          </span>
        )}
      </div>

      {consensusConfirmed && (
        <div className="mb-4">
          <ConsensusBadge
            eventTxHash={event.tx_hash}
            variant={focal ? "detail" : "mark"}
          />
        </div>
      )}

      {backfillText && (
        <p className="mb-4 text-[11px] italic leading-relaxed text-foreground-dim">
          {backfillText} — replayed through the verifier manually, not caught
          by a live-running feed listener.
        </p>
      )}

      <PipelineStatusBar event={event} emphasized={focal} />
    </motion.div>
  );
}
