"use client";

import { useEffect, useMemo, useState } from "react";
import { AuditEvent, getTokenVerificationStatus } from "@/lib/api";

export interface ConsensusConfirmation {
  /** The mainnet V2 registry that holds the record. */
  registryAddress: string;
  /** Unix seconds, as recorded on-chain. */
  recordedAt?: number;
}

/**
 * Asks the mainnet consensus registry (V2) which of these events it has
 * confirmed, keyed by the event's tx hash, lowercased.
 *
 * Deliberately a second, additive read: every screen's primary data still
 * comes from V1 and renders whether or not this resolves. A failed lookup
 * yields an empty map, which just means no badges -- never an error state, and
 * never a blocked render.
 *
 * Scope worth knowing: V2 exposes `latestVerificationForToken`, so this can
 * only see each token's MOST RECENT confirmation. An older confirmed event for
 * a token that has since been confirmed again would stop being marked here.
 * With writes to V2 being manual (README Honest Disclosures #13) there is
 * currently one confirmation in total, so this costs one request per distinct
 * token and no accuracy. If V2 ever holds several records per token, this
 * needs a per-event read instead.
 */
export function useConsensusConfirmations(events: AuditEvent[] | null) {
  const [confirmations, setConfirmations] = useState<
    Map<string, ConsensusConfirmation>
  >(new Map());

  // Key off the distinct token set, not the events array: the feed and audit
  // log rebuild that array every 5s poll, and re-requesting a decorative badge
  // at that rate would be pure noise against the API.
  const tokenKey = useMemo(() => {
    if (!events || events.length === 0) return "";
    return Array.from(
      new Set(events.map((e) => e.token_address.toLowerCase()))
    )
      .sort()
      .join(",");
  }, [events]);

  useEffect(() => {
    if (!tokenKey) return;
    let cancelled = false;

    const tokens = tokenKey.split(",");
    Promise.all(
      tokens.map((token) =>
        getTokenVerificationStatus(token, "v2").catch(() => null)
      )
    ).then((results) => {
      if (cancelled) return;
      const next = new Map<string, ConsensusConfirmation>();
      for (const status of results) {
        if (!status?.ever_verified || !status.latest_event_hash) continue;
        next.set(status.latest_event_hash.toLowerCase(), {
          registryAddress: status.registry_address,
          recordedAt: status.recorded_at,
        });
      }
      setConfirmations(next);
    });

    return () => {
      cancelled = true;
    };
  }, [tokenKey]);

  return confirmations;
}

/** Convenience for the common single-event check. */
export function isConsensusConfirmed(
  confirmations: Map<string, ConsensusConfirmation>,
  txHash: string
): boolean {
  return confirmations.has(txHash.toLowerCase());
}
