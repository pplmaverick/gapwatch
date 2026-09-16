// The authoritative signal for "has this event been consensus-confirmed on
// mainnet" is the API's own `registry_source=v2` response -- not this file.
// This file supplies only the hash of the `recordVerification` transaction that
// wrote each confirmation, because the registry stores the verification record
// but not the hash of the transaction that carried it, and there is no
// on-chain field to read it back from. Same division of labour as
// knownBackfills.ts: live truth from the API, display-only trivia from here.
//
// Writes to V2 are manual by design (see README Honest Disclosures #13), so
// this list grows one deliberate entry at a time rather than automatically.

export const MAINNET_EXPLORER = "https://robinhoodchain.blockscout.com";

export interface KnownConsensusRecord {
  /** The original on-chain event, used as `eventHash` in the registry. */
  eventHash: string;
  /** The mainnet tx that called `recordVerification` with 2-of-3 signatures. */
  recordTxHash: string;
}

export const KNOWN_CONSENSUS_RECORDS: KnownConsensusRecord[] = [
  {
    eventHash:
      "0x4ac23f2e58e2c4962dcd701c2beff581e87f3995152a29d527c07a3afd67d956",
    recordTxHash:
      "0x11255751af281f9179a5b19dfecfdf53a6d377d700fffd00b00531517d38d369",
  },
];

export function findConsensusRecord(
  eventHash: string
): KnownConsensusRecord | undefined {
  return KNOWN_CONSENSUS_RECORDS.find(
    (r) => r.eventHash.toLowerCase() === eventHash.toLowerCase()
  );
}

export function explorerTxUrl(txHash: string): string {
  return `${MAINNET_EXPLORER}/tx/${txHash}`;
}

export function shortHash(hash: string): string {
  return `${hash.slice(0, 10)}…${hash.slice(-8)}`;
}
