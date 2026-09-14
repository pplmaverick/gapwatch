"use client";

import { AuditEvent } from "@/lib/api";
import { findKnownToken } from "@/lib/tokens";
import { backfillLabel } from "@/lib/knownBackfills";

function shortAddress(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function formatDate(iso: string) {
  return (
    new Date(iso).toLocaleString("en-US", {
      timeZone: "UTC",
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }) + " UTC"
  );
}

function StatusBadge({ status }: { status: AuditEvent["status"] }) {
  const config: Record<AuditEvent["status"], { label: string; color: string }> = {
    pending: { label: "Pending", color: "var(--foreground-muted)" },
    filter_check_in_progress: {
      label: "Querying filter",
      color: "var(--foreground-muted)",
    },
    confirmed_not_filtered: {
      label: "Verified, not filtered",
      color: "var(--semantic-confirmed)",
    },
    filtered: { label: "Filtered — excluded", color: "#f87171" },
    l1_confirmed: { label: "Confirmed on L1", color: "var(--semantic-confirmed)" },
  };
  const c = config[status];
  return (
    <span className="text-[12px] font-medium" style={{ color: c.color }}>
      {c.label}
    </span>
  );
}

export function AuditLogTable({ events }: { events: AuditEvent[] }) {
  if (events.length === 0) {
    return (
      <p className="px-1 py-8 text-[13px] text-foreground-dim">
        No candidate events detected yet.
      </p>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[720px] text-left text-[13px]">
        <thead>
          <tr className="text-[11px] uppercase tracking-wide text-foreground-dim">
            <th className="py-3 pr-4 font-medium">Token</th>
            <th className="py-3 pr-4 font-medium">Status</th>
            <th className="py-3 pr-4 font-medium">Detected</th>
            <th className="py-3 pr-4 font-medium">Block</th>
            <th className="py-3 pr-4 font-medium">Checks</th>
            <th className="py-3 pr-4 font-medium">Tx hash</th>
            <th className="py-3 pr-0 font-medium">Source</th>
          </tr>
        </thead>
        <tbody>
          {events.map((event) => {
            const token = findKnownToken(event.token_address);
            const backfillText = backfillLabel(event);
            return (
              <tr
                key={event.id}
                className="border-t"
                style={{ borderColor: "var(--border-soft)" }}
              >
                <td className="py-3 pr-4">
                  <span className="font-medium text-foreground">
                    {token ? token.symbol : shortAddress(event.token_address)}
                  </span>
                </td>
                <td className="py-3 pr-4">
                  <StatusBadge status={event.status} />
                </td>
                <td className="py-3 pr-4 font-mono text-[12px] text-foreground-muted">
                  {formatDate(event.detected_at)}
                </td>
                <td className="py-3 pr-4 font-mono text-[12px] text-foreground-muted">
                  {event.block_number}
                </td>
                <td className="py-3 pr-4 font-mono text-[12px] text-foreground-muted">
                  {event.filter_check_count}
                </td>
                <td className="py-3 pr-4 font-mono text-[12px] text-foreground-dim">
                  {shortAddress(event.tx_hash)}
                </td>
                <td className="py-3 pr-0 text-[11px] italic text-foreground-dim">
                  {backfillText ?? ""}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
