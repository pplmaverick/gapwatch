import { AuditEvent } from "./api";

function triggerBlobDownload(filename: string, content: string, mime: string) {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

export function downloadAuditLogJson(events: AuditEvent[]) {
  triggerBlobDownload(
    "gapwatch-audit-log.json",
    JSON.stringify(events, null, 2),
    "application/json"
  );
}

// Kept aligned with the columns AuditLogTable actually renders (Token,
// Status, ..., Source) -- a CSV that can't answer the same questions the
// on-screen table can is a broken export, not a smaller one.
const CSV_COLUMNS: (keyof AuditEvent)[] = [
  "id",
  "token_address",
  "symbol",
  "tx_hash",
  "block_number",
  "detected_at",
  "status",
  "filter_check_count",
  "last_checked_at",
  "reference_model_hash",
  "source",
];

function csvEscape(value: unknown): string {
  const str = value === null || value === undefined ? "" : String(value);
  if (/[",\n]/.test(str)) return `"${str.replace(/"/g, '""')}"`;
  return str;
}

export function downloadAuditLogCsv(events: AuditEvent[]) {
  const header = CSV_COLUMNS.join(",");
  const rows = events.map((e) =>
    CSV_COLUMNS.map((col) => csvEscape(e[col])).join(",")
  );
  triggerBlobDownload(
    "gapwatch-audit-log.csv",
    [header, ...rows].join("\n"),
    "text/csv"
  );
}
