// Alert relay storage: the types of docs/APP.md and the KV layout.
//
//   devices        one JSON array, at most MAX_DEVICES, oldest first
//   alerts         one JSON array, newest first, at most MAX_ALERTS
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
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
}

export const MAX_DEVICES = 10;
export const MAX_ALERTS = 100;
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
export const loadAlerts = (kv: KV): Promise<Alert[]> => readJson<Alert[]>(kv, "alerts", []);

/**
 * Adds or refreshes a device. Re-registering a token moves it to the newest
 * slot; past MAX_DEVICES the oldest are dropped. Writes only on a change.
 */
export async function addDevice(kv: KV, device: Device): Promise<void> {
  const devices = await loadDevices(kv);
  const same = devices.find((d) => d.token === device.token);
  if (same && same.environment === device.environment && same.name === device.name) return;
  const next = [...devices.filter((d) => d.token !== device.token), device].slice(-MAX_DEVICES);
  await kv.put("devices", JSON.stringify(next));
}

export async function removeDevices(kv: KV, tokens: string[]): Promise<void> {
  if (tokens.length === 0) return;
  const devices = await loadDevices(kv);
  const next = devices.filter((d) => !tokens.includes(d.token));
  if (next.length !== devices.length) await kv.put("devices", JSON.stringify(next));
}

/** Newest first, capped. */
export async function addAlert(kv: KV, alert: Alert): Promise<void> {
  const alerts = await loadAlerts(kv);
  await kv.put("alerts", JSON.stringify([alert, ...alerts].slice(0, MAX_ALERTS)));
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
