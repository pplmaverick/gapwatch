// Some rows in events.db were not caught by a live-running feed listener --
// they were verified by manually replaying a known historical broadcast
// through filter_verifier.check_event()/l1_confirmer.check_event() directly,
// bypassing main.py's state-machine loop. Confirmed 2026-09-14 by comparing
// detected_at/last_checked_at against the real on-chain broadcast time (5
// days apart) and against the 15s-sleep + 2-block-gap timing main.py's loop
// requires (3 filter checks + L1 confirmation in 4.45s is not physically
// possible through that loop). Recorded here so the UI can say so plainly
// instead of implying every row was caught in real time.
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
