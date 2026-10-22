// Alert relay storage: the types of docs/APP.md and the KV layout.
//
//   devices        one JSON array, at most MAX_DEVICES, oldest first
//   alert:<key>    one key per alert, the Alert itself in the key's metadata;
//                  keys sort newest first and expire after ALERT_TTL_S
//   dedupe:<key>   a marker that expires after DEDUPE_TTL_S
//   state          the monitor's own state (index.ts / monitor.ts)
//
// No Cloudflare APIs in here, so it runs under `node --test`.

export type Severity = "critical" | "warning" | "info";
export type Source = "monitor" | "host" | "app";

/** What a host script posts. */
export interface Event {
  kind: string;
  severity: Severity;
  title: string;
  body: string;
  dedupe?: string;
}

export interface Alert {
  id: string;
  at: string;
  source: Source;
  kind: string;
  severity: Severity;
  title: string;
  body: string;
}

export interface Device {
  /** APNs device token, lowercase hex. */
  token: string;
  environment: "sandbox" | "production";
  name: string;
  /** ISO time of the registration. */
  addedAt: string;
}

/** The part of KVNamespace the relay uses; tests pass an in-memory fake. */
export interface KV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number; metadata?: unknown }): Promise<void>;
  list(options: { prefix: string; limit: number }): Promise<{ keys: { name: string; metadata?: unknown }[] }>;
}

export const MAX_DEVICES = 10;
/** The most alerts one read returns (the app asks for at most 100). */
export const MAX_ALERTS = 100;
/** Thirty days. */
export const ALERT_TTL_S = 30 * 86400;
/** KV allows 1024 bytes of metadata; stay under it. */
const MAX_METADATA_BYTES = 1000;
/** Six hours. KV needs at least 60. */
export const DEDUPE_TTL_S = 21600;

async function readJson<T>(kv: KV, key: string, fallback: T): Promise<T> {
  const raw = await kv.get(key);
  if (!raw) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export const loadDevices = (kv: KV): Promise<Device[]> => readJson<Device[]>(kv, "devices", []);

/** Newest first, at most `limit` (up to MAX_ALERTS). One list() call, no per-alert get. */
export async function loadAlerts(kv: KV, limit = MAX_ALERTS): Promise<Alert[]> {
  const { keys } = await kv.list({ prefix: "alert:", limit: Math.min(limit, MAX_ALERTS) });
  return keys.flatMap((k) => (k.metadata ? [k.metadata as Alert] : []));
}

/**
 * Adds or refreshes a device. A token that is already known is removed and
 * appended, so the phone that just registered is the newest and is not the one
 * dropped past MAX_DEVICES (the oldest go).
 */
export async function addDevice(kv: KV, device: Device): Promise<void> {
  const devices = await loadDevices(kv);
  const next = [...devices.filter((d) => d.token !== device.token), device].slice(-MAX_DEVICES);
  await kv.put("devices", JSON.stringify(next));
}

export async function removeDevices(kv: KV, tokens: string[]): Promise<void> {
  if (tokens.length === 0) return;
  const devices = await loadDevices(kv);
  const next = devices.filter((d) => !tokens.includes(d.token));
  if (next.length !== devices.length) await kv.put("devices", JSON.stringify(next));
}

/** Shortens the body, then the title, until the alert fits KV's metadata limit. */
export function fitMetadata(alert: Alert): Alert {
  const bytes = (a: Alert) => new TextEncoder().encode(JSON.stringify(a)).length;
  const fitted = { ...alert };
  for (const field of ["body", "title"] as const) {
    while (bytes(fitted) > MAX_METADATA_BYTES && fitted[field].length > 0) {
      fitted[field] = fitted[field].slice(0, Math.floor(fitted[field].length * 0.9));
    }
  }
  return fitted;
}

/**
 * Key of an alert: 13 digits of (9999999999999 - epoch ms), then the random
 * part of its id. KV lists keys in ascending order, so the newest comes first.
 */
export function alertKey(alert: Alert): string {
  const inverted = String(9999999999999 - Date.parse(alert.at)).padStart(13, "0");
  return `alert:${inverted}-${alert.id.split("-")[1] ?? ""}`;
}

/** Each alert is its own key, so two writers never overwrite each other. */
export async function addAlert(kv: KV, alert: Alert): Promise<void> {
  const stored = fitMetadata(alert);
  await kv.put(alertKey(stored), "1", { expirationTtl: ALERT_TTL_S, metadata: stored });
}

export async function isDeduped(kv: KV, key: string): Promise<boolean> {
  return (await kv.get(`dedupe:${key}`)) !== null;
}

export async function markDeduped(kv: KV, key: string): Promise<void> {
  await kv.put(`dedupe:${key}`, "1", { expirationTtl: DEDUPE_TTL_S });
}

/** Sorts by time as text: 12 hex digits of epoch milliseconds, then 6 random ones. */
export function newAlertId(nowMs: number): string {
  const rand = crypto.getRandomValues(new Uint8Array(3));
  const suffix = Array.from(rand, (b) => b.toString(16).padStart(2, "0")).join("");
  return `${nowMs.toString(16).padStart(12, "0")}-${suffix}`;
}
