"use client";

import { useEffect, useState } from "react";
import { motion, AnimatePresence } from "motion/react";
import {
  ApiError,
  AuditEvent,
  EventDetail,
  getEventDetail,
  getTokenBalance,
} from "@/lib/api";
import { backfillLabel } from "@/lib/knownBackfills";
import { useInView } from "@/lib/useInView";
import { ConsensusBadge } from "./ConsensusBadge";
import type { ConsensusConfirmation } from "@/lib/useConsensusConfirmations";

/** Loosened from the old KnownToken (5-item hardcoded list): the full
 *  registry from /tokens/known doesn't guarantee a symbol/name for every
 *  address, so both are nullable here and rendered with a fallback. */
export interface BalanceRowToken {
  address: string;
  symbol: string | null;
  name: string | null;
}

function shortAddress(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function formatMultiplier(raw: number) {
  return (raw / 1e18).toFixed(6);
}

function formatDate(iso: string) {
  // Fixed locale/timezone -- not the runtime default -- so server and client
  // render the same string on first paint (see PipelineStatusBar for the
  // hydration mismatch this avoids).
  return (
    new Date(iso).toLocaleString("en-US", {
      timeZone: "UTC",
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    }) + " UTC"
  );
}

interface Props {
  token: BalanceRowToken;
  holderAddress: string;
  matchedEvents: AuditEvent[];
  /** Keyed by lowercased event tx hash; empty until the V2 lookup resolves. */
  confirmations?: Map<string, ConsensusConfirmation>;
  /** True: fetch the balance as soon as `holderAddress` is set (today's
   *  behavior -- used for the handful of tokens shown up front). False:
   *  wait until this row actually scrolls into view before firing the RPC
   *  call, so an expanded ~190-row collapsed section doesn't fire that many
   *  concurrent requests at once. */
  eager?: boolean;
}

type BalanceState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "loaded"; value: number }
  | { status: "error"; message: string };

export function TokenRow({
  token,
  holderAddress,
  matchedEvents,
  confirmations,
  eager = true,
}: Props) {
  const [balance, setBalance] = useState<BalanceState>({ status: "idle" });
  const [expanded, setExpanded] = useState(false);
  const [details, setDetails] = useState<Record<number, EventDetail | "loading" | "error">>(
    {}
  );
  const [rowRef, inView] = useInView<HTMLDivElement>();
  const shouldFetchBalance = eager || inView;

  useEffect(() => {
    if (!holderAddress || !shouldFetchBalance) {
      // prop 變動觸發的資料抓取流程：沒有 holderAddress（或還沒該抓，見
      // shouldFetchBalance）就重置回 idle，該抓的時候才在下方先設定 loading
      // 狀態、緊接著發送非同步請求。兩者都是刻意的狀態設定，不是規則要抓的
      // 可疑模式。
      // eslint-disable-next-line react-hooks/set-state-in-effect -- 非可疑的 effect 內同步 setState 模式
      setBalance({ status: "idle" });
      return;
    }
    let cancelled = false;
    setBalance({ status: "loading" });
    getTokenBalance(token.address, holderAddress)
      .then((res) => {
        if (!cancelled) setBalance({ status: "loaded", value: res.balance_ui });
      })
      .catch((err) => {
        if (!cancelled) {
          setBalance({
            status: "error",
            message: err instanceof ApiError ? err.message : "read failed",
          });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [token.address, holderAddress, shouldFetchBalance]);

  function toggleExpanded() {
    const next = !expanded;
    setExpanded(next);
    if (next) {
      for (const event of matchedEvents) {
        if (details[event.id]) continue;
        setDetails((d) => ({ ...d, [event.id]: "loading" }));
        getEventDetail(event.id)
          .then((detail) =>
            setDetails((d) => ({ ...d, [event.id]: detail }))
          )
          .catch(() => setDetails((d) => ({ ...d, [event.id]: "error" })));
      }
    }
  }

  const isZero = balance.status === "loaded" && balance.value === 0;

  return (
    <div
      ref={rowRef}
      className="border-b"
      style={{ borderColor: "var(--border-soft)" }}
    >
      <button
        onClick={toggleExpanded}
        className="flex w-full items-center gap-4 px-5 py-4 text-left transition-colors hover:bg-background-raised"
      >
        <motion.span
          animate={{ rotate: expanded ? 90 : 0 }}
          transition={{ type: "spring", damping: 1, duration: 0.35 }}
          className="text-[11px] text-foreground-dim"
        >
          ▶
        </motion.span>

        <div className="flex min-w-[110px] flex-col">
          <span
            className="text-[14px] font-medium tracking-tight"
            style={{ color: isZero ? "var(--foreground-dim)" : "var(--foreground)" }}
          >
            {token.symbol ?? shortAddress(token.address)}
          </span>
          {token.name && (
            <span className="text-[11px] text-foreground-dim">{token.name}</span>
          )}
        </div>

        <span className="hidden font-mono text-[12px] text-foreground-dim sm:inline">
          {shortAddress(token.address)}
        </span>

        {matchedEvents.length > 0 && (
          <span
            className="rounded-full px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide"
            style={{
              color: "var(--semantic-confirmed)",
              background: "var(--semantic-confirmed-dim)",
            }}
          >
            {matchedEvents.length} verified event
            {matchedEvents.length > 1 ? "s" : ""}
          </span>
        )}

        <span className="ml-auto text-right">
          {balance.status === "idle" && (
            <span className="text-[13px] text-foreground-dim">—</span>
          )}
          {balance.status === "loading" && (
            <span className="text-[13px] text-foreground-dim">loading…</span>
          )}
          {balance.status === "error" && (
            <span className="text-[12px] text-red-400">{balance.message}</span>
          )}
          {balance.status === "loaded" && (
            <span
              className="text-[17px] font-semibold tracking-tight tabular-nums"
              style={{ color: isZero ? "var(--foreground-dim)" : "var(--foreground)" }}
            >
              {balance.value.toLocaleString(undefined, {
                maximumFractionDigits: 4,
              })}
            </span>
          )}
        </span>
      </button>

      <AnimatePresence initial={false}>
        {expanded && (
          <motion.div
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ type: "spring", damping: 1, duration: 0.4 }}
            className="overflow-hidden"
          >
            <div className="px-5 pb-5 pl-12">
              <p className="mb-3 text-[11px] font-medium uppercase tracking-[0.12em] text-foreground-dim">
                Multiplier change history
              </p>
              {matchedEvents.length === 0 ? (
                <p className="text-[13px] text-foreground-dim">
                  No multiplier-update events detected for this token yet.
                </p>
              ) : (
                <div className="flex flex-col gap-3">
                  {matchedEvents.map((event) => {
                    const detail = details[event.id];
                    return (
                      <div
                        key={event.id}
                        className="rounded-lg border px-4 py-3"
                        style={{ borderColor: "var(--border-soft)" }}
                      >
                        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[12px] text-foreground-muted">
                          <span className="font-mono">{shortAddress(event.tx_hash)}</span>
                          <span>block {event.block_number}</span>
                          <span>{formatDate(event.detected_at)}</span>
                        </div>

                        {backfillLabel(event) && (
                          <p className="mt-1 text-[11px] italic text-foreground-dim">
                            {backfillLabel(event)}
                          </p>
                        )}

                        {confirmations?.has(event.tx_hash.toLowerCase()) && (
                          <div className="mt-2">
                            <ConsensusBadge
                              eventTxHash={event.tx_hash}
                              variant="detail"
                            />
                          </div>
                        )}

                        {detail === "loading" && (
                          <p className="mt-2 text-[12px] text-foreground-dim">
                            reading GapwatchRegistry…
                          </p>
                        )}
                        {detail === "error" && (
                          <p className="mt-2 text-[12px] text-red-400">
                            on-chain read failed
                          </p>
                        )}
                        {detail && typeof detail === "object" && (
                          <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-[13px]">
                            {detail.onchain ? (
                              <>
                                <span className="tabular-nums">
                                  {formatMultiplier(detail.onchain.old_multiplier)} →{" "}
                                  {formatMultiplier(detail.onchain.new_multiplier)}
                                </span>
                                <span
                                  className="rounded-full px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide"
                                  style={{
                                    color: "var(--semantic-confirmed)",
                                    background: "var(--semantic-confirmed-dim)",
                                  }}
                                >
                                  Confirmed on L1
                                </span>
                                <span className="text-foreground-dim">
                                  {detail.onchain.was_filtered
                                    ? "was filtered"
                                    : "not filtered"}
                                </span>
                              </>
                            ) : (
                              <span className="text-foreground-dim">
                                not yet recorded on-chain (status: {event.status})
                              </span>
                            )}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
