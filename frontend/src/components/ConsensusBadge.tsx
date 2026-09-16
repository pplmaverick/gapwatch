"use client";

import {
  explorerTxUrl,
  findConsensusRecord,
  shortHash,
} from "@/lib/knownConsensusRecords";

interface Props {
  /** The event's own tx hash, which is also its `eventHash` in the registry. */
  eventTxHash: string;
  /**
   * `compact` is a short pill for table cells, where the full phrase is both
   * the widest thing in the row and enough to push the table into horizontal
   * scroll; `mark` is the full phrase; `detail` adds the record transaction
   * underneath.
   */
  variant?: "compact" | "mark" | "detail";
}

/**
 * Marks an event that the mainnet consensus registry has confirmed.
 *
 * Intentionally understated: this is a secondary layer on top of what each
 * screen already shows from V1, so it borrows the cyan accent rather than the
 * green every screen uses for "verified", and never takes a whole row or a
 * heading slot. Only render it when `useConsensusConfirmations` says the
 * registry actually holds the record -- the caller decides, not this component.
 */
const FULL_LABEL = "Tier 3 consensus confirmed";

export function ConsensusBadge({ eventTxHash, variant = "mark" }: Props) {
  const record = findConsensusRecord(eventTxHash);

  const pill = (
    <span
      title={variant === "compact" ? FULL_LABEL : undefined}
      className="inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide whitespace-nowrap"
      style={{
        color: "var(--interactive)",
        background: "var(--interactive-dim)",
      }}
    >
      <span
        className="h-[5px] w-[5px] shrink-0 rounded-full"
        style={{ background: "var(--interactive)" }}
      />
      {variant === "compact" ? "Tier 3" : FULL_LABEL}
    </span>
  );

  if (variant === "compact" || variant === "mark") return pill;

  return (
    // items-start: without it the column stretches the pill to full width.
    <div className="flex flex-col items-start gap-1.5">
      {pill}
      {record ? (
        <a
          href={explorerTxUrl(record.recordTxHash)}
          target="_blank"
          rel="noreferrer"
          className="font-mono text-[11px] text-foreground-dim transition-colors hover:text-interactive"
        >
          {shortHash(record.recordTxHash)} ↗
        </a>
      ) : (
        // The registry confirmed it, but this build has no record of which
        // transaction wrote it. Say so rather than rendering a dead link.
        <span className="text-[11px] text-foreground-dim">
          record transaction not listed in this build
        </span>
      )}
    </div>
  );
}
