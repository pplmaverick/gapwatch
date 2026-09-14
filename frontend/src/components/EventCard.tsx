"use client";

import { motion } from "motion/react";
import { AuditEvent } from "@/lib/api";
import { findKnownToken } from "@/lib/tokens";
import { findBackfill } from "@/lib/knownBackfills";
import { PipelineStatusBar } from "./PipelineStatusBar";

function formatBroadcastDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-US", {
    timeZone: "UTC",
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

function shortAddress(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

interface Props {
  event: AuditEvent;
  focal: boolean;
}

export function EventCard({ event, focal }: Props) {
  const token = findKnownToken(event.token_address);
  const backfill = findBackfill(event.tx_hash);

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
          {token ? token.symbol : shortAddress(event.token_address)}
        </span>
        {token && (
          <span className="text-[12px] text-foreground-dim">{token.name}</span>
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

      {backfill && (
        <p className="mb-4 text-[11px] italic leading-relaxed text-foreground-dim">
          Verified from historical broadcast ({formatBroadcastDate(backfill.broadcastAt)})
          — replayed through the verifier manually, not caught by a live-running
          feed listener.
        </p>
      )}

      <PipelineStatusBar event={event} emphasized={focal} />
    </motion.div>
  );
}
