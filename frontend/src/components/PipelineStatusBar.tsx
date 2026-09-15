"use client";

import { motion, AnimatePresence } from "motion/react";
import { AuditEvent } from "@/lib/api";

const SPRING = { type: "spring" as const, damping: 1, duration: 0.45 };

function formatTime(iso: string | null) {
  if (!iso) return null;
  // Fixed locale/timezone (not `undefined`) so server-rendered markup always
  // matches the client's first render, regardless of either one's runtime
  // locale -- otherwise this mismatches and React throws a hydration error.
  return new Date(iso).toLocaleTimeString("en-US", {
    timeZone: "UTC",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }) + " UTC";
}

// "fact" = a neutral, factual thing that happened (e.g. detection) -- not a
// verification claim, so it must never render in the semantic-confirmed
// (mint) color reserved for "done". Only "done" gets that color.
type DotState = "pending" | "active" | "fact" | "done" | "failed";

function Dot({ state }: { state: DotState }) {
  const color =
    state === "done"
      ? "var(--semantic-confirmed)"
      : state === "failed"
        ? "#f87171"
        : state === "fact"
          ? "var(--foreground)"
          : state === "active"
            ? "var(--foreground-muted)"
            : "var(--foreground-dim)";

  return (
    <motion.span
      className="relative flex h-3 w-3 shrink-0 items-center justify-center rounded-full"
      animate={{
        background:
          state === "done" || state === "failed" || state === "fact"
            ? color
            : "transparent",
        borderColor: color,
        scale: state === "active" ? [1, 1.15, 1] : 1,
      }}
      transition={
        state === "active"
          ? { repeat: Infinity, duration: 1.6, ease: "easeInOut" }
          : SPRING
      }
      style={{ borderWidth: 1.5, borderStyle: "solid" }}
    />
  );
}

function progressFraction(status: AuditEvent["status"]) {
  switch (status) {
    case "pending":
    case "filter_check_in_progress":
      return 0.02;
    case "confirmed_not_filtered":
      return 0.5;
    case "l1_confirmed":
      return 1;
    case "filtered":
      return 0.5;
    default:
      return 0;
  }
}

function ConnectorLine({ active }: { active: boolean }) {
  return (
    <div
      className="relative mx-2 h-px flex-1"
      style={{ background: "var(--border-soft)" }}
    >
      <motion.div
        className="absolute inset-y-0 left-0"
        style={{ background: "var(--semantic-confirmed)" }}
        initial={false}
        animate={{ width: active ? "100%" : "0%" }}
        transition={SPRING}
      />
    </div>
  );
}

interface Props {
  event: AuditEvent;
  emphasized: boolean;
}

export function PipelineStatusBar({ event, emphasized }: Props) {
  const isQuerying =
    event.status === "pending" || event.status === "filter_check_in_progress";
  const isFiltered = event.status === "filtered";
  const isVerified =
    event.status === "confirmed_not_filtered" || event.status === "l1_confirmed";
  const isL1Confirmed = event.status === "l1_confirmed";

  const stage1Dot: DotState = "fact"; // a neutral fact (seen on feed), not a verification claim
  const stage2Dot: DotState = isFiltered
    ? "failed"
    : isVerified
      ? "done"
      : isQuerying
        ? "active"
        : "pending";
  const stage3Dot: DotState = isL1Confirmed ? "done" : "pending";

  const textSize = emphasized ? "text-[13px]" : "text-[12px]";
  const dim = emphasized ? "text-foreground-muted" : "text-foreground-dim";

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center">
        <Dot state={stage1Dot} />
        <ConnectorLine active={progressFraction(event.status) >= 0.5} />
        <Dot state={stage2Dot} />
        <ConnectorLine active={progressFraction(event.status) >= 1} />
        <Dot state={stage3Dot} />
      </div>

      <div className="flex items-start justify-between gap-4">
        <div className={`flex flex-col ${textSize}`}>
          <span className={isQuerying ? "text-foreground-muted" : dim}>
            Detected on feed
          </span>
          <span className="font-mono text-[11px] text-foreground-dim">
            {formatTime(event.detected_at) ?? "—"}
          </span>
        </div>

        <div className={`flex flex-1 flex-col items-center ${textSize}`}>
          <AnimatePresence mode="wait" initial={false}>
            {isQuerying ? (
              <motion.span
                key="querying"
                initial={{ opacity: 0, y: 4 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -4 }}
                transition={SPRING}
                className="text-foreground-muted"
              >
                Querying… (checked {event.filter_check_count}×)
              </motion.span>
            ) : isFiltered ? (
              <motion.span
                key="filtered"
                initial={{ opacity: 0, y: 4 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -4 }}
                transition={SPRING}
                style={{ color: "#f87171" }}
              >
                Filtered — excluded
              </motion.span>
            ) : (
              <motion.span
                key="verified"
                initial={{ opacity: 0, y: 4 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -4 }}
                transition={SPRING}
                style={{ color: isVerified ? "var(--semantic-confirmed)" : undefined }}
                className={isVerified ? "" : dim}
              >
                Verified not filtered
              </motion.span>
            )}
          </AnimatePresence>
          <span
            className="font-mono text-[11px] text-foreground-dim"
            title={
              isL1Confirmed
                ? "exact time not retained once confirmed on L1 (last_checked_at is overwritten by that transition)"
                : undefined
            }
          >
            {isQuerying || isFiltered
              ? (formatTime(event.last_checked_at) ?? "—")
              : isVerified && !isL1Confirmed
                ? (formatTime(event.last_checked_at) ?? "—")
                : isL1Confirmed
                  ? "— (see Confirmed on L1)"
                  : "—"}
          </span>
        </div>

        <div className={`flex flex-col items-end text-right ${textSize}`}>
          <span
            style={{
              color: isL1Confirmed ? "var(--semantic-confirmed)" : undefined,
            }}
            className={isL1Confirmed ? "" : dim}
          >
            Confirmed on L1
          </span>
          <span className="font-mono text-[11px] text-foreground-dim">
            {isL1Confirmed ? (formatTime(event.last_checked_at) ?? "—") : "—"}
          </span>
        </div>
      </div>
    </div>
  );
}
