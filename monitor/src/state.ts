// The monitor's stored state and the `monitor` object of GET /v1/alerts.

import type { KV } from "./store.ts";
import type { MonitorState } from "./transition.ts";

export interface TargetEnv {
  STATE: KV;
  TARGET_HOST?: string;
  TARGET_PORT?: string;
}

export const STATE_KEY = "state";

/** The state machine's state plus what the API reports. */
export interface StoredState extends MonitorState {
  /** ISO time of the last run. */
  lastCheck?: string;
  /** host:port that was checked. */
  target?: string;
}

/** The `monitor` object of GET /v1/alerts. */
export interface MonitorView {
  status: "up" | "down" | "unknown";
  since: string | null;
  lastCheck: string | null;
  ip: string | null;
  target: string;
}

export function targetOf(env: TargetEnv): string {
  return `${env.TARGET_HOST ?? ""}:${env.TARGET_PORT ?? "443"}`;
}

export async function loadState(kv: KV): Promise<StoredState | null> {
  const raw = await kv.get(STATE_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as StoredState;
  } catch {
    return null;
  }
}

export async function monitorView(env: TargetEnv): Promise<MonitorView> {
  const s = await loadState(env.STATE);
  const target = s?.target ?? targetOf(env);
  if (!s) return { status: "unknown", since: null, lastCheck: null, ip: null, target };
  return { status: s.status, since: s.since, lastCheck: s.lastCheck ?? null, ip: s.ip, target };
}
