// Always same-origin, same-protocol -- see the rewrite in next.config.ts for
// where this actually goes server-side. The browser must never be given the
// real (HTTP) backend URL directly, or HTTPS pages block it as mixed content.
const API_BASE_URL = "/api/backend";

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(`${API_BASE_URL}${path}`);
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new ApiError(res.status, body || res.statusText);
  }
  return res.json() as Promise<T>;
}

export interface TokenBalance {
  token: string;
  holder: string;
  balance_ui_raw: number;
  balance_ui: number;
}

export function getTokenBalance(tokenAddress: string, holderAddress: string) {
  return getJson<TokenBalance>(
    `/tokens/${tokenAddress}/balance/${holderAddress}`
  );
}

export type EventStatus =
  | "pending"
  | "filter_check_in_progress"
  | "confirmed_not_filtered"
  | "filtered"
  | "l1_confirmed";

export type EventSource = "live_detection" | "historical_backfill";

export interface AuditEvent {
  id: number;
  token_address: string;
  tx_hash: string;
  block_number: number;
  detected_at: string;
  status: EventStatus;
  filter_check_count: number;
  last_checked_at: string | null;
  reference_model_hash: string | null;
  onchain_verified_cache: boolean | null;
  onchain_cache_updated_at: string | null;
  source: EventSource;
}

export interface AuditLogResponse {
  count: number;
  events: AuditEvent[];
}

export function getAuditLog(status?: EventStatus) {
  const qs = status ? `?status=${status}` : "";
  return getJson<AuditLogResponse>(`/audit-log${qs}`);
}

export interface EventsListResponse {
  total: number;
  limit: number;
  offset: number;
  events: AuditEvent[];
}

export function getEvents(limit = 50, offset = 0) {
  return getJson<EventsListResponse>(`/events?limit=${limit}&offset=${offset}`);
}

export interface OnchainVerification {
  registry_address: string;
  tx_hash_used_as_event_hash: string;
  token: string;
  old_multiplier: number;
  new_multiplier: number;
  was_filtered: boolean;
  reference_model_hash: string;
  recorded_at: number;
  bond: number;
  recorded_by: string;
}

export interface EventDetail extends AuditEvent {
  onchain: OnchainVerification | null;
}

export function getEventDetail(eventId: number) {
  return getJson<EventDetail>(`/events/${eventId}`);
}

export interface VerificationStatus {
  token: string;
  registry_address: string;
  ever_verified: boolean;
  latest_event_hash: string | null;
  has_discrepancy: boolean | null;
  old_multiplier?: number;
  new_multiplier?: number;
  was_filtered?: boolean;
  recorded_at?: number;
}

export function getTokenVerificationStatus(tokenAddress: string) {
  return getJson<VerificationStatus>(
    `/tokens/${tokenAddress}/verification-status`
  );
}
