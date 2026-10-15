// Pure state machine for the uptime monitor. No Cloudflare APIs in here, so
// it runs under `node --test` (Node 22.18+ strips the types natively).

export type Status = "up" | "down";

export interface MonitorState {
  /** What we last told the owner. Alerts fire only when this changes. */
  status: Status;
  /** Consecutive failed checks since the last success. */
  failures: number;
  /** Last IP vpn.example.com resolved to, if any. */
  ip: string | null;
  /** ISO time the current status began. */
  since: string;
}

export interface CheckResult {
  ok: boolean;
  /** IP from DNS-over-HTTPS, null if resolution failed. */
  ip: string | null;
  /** Why it failed, for the alert text. */
  error?: string;
}

export type Alert = { kind: "down" | "recovered"; message: string };

/** Down is declared after this many failures in a row (one blip is ignored). */
export const FAILURES_BEFORE_DOWN = 2;

export function initialState(now: string): MonitorState {
  return { status: "up", failures: 0, ip: null, since: now };
}

export function transition(
  prev: MonitorState,
  result: CheckResult,
  now: string,
  host = "vpn.example.com:443",
): { state: MonitorState; alert: Alert | null } {
  const ip = result.ip ?? prev.ip;

  if (result.ok) {
    if (prev.status === "down") {
      return {
        state: { status: "up", failures: 0, ip, since: now },
        alert: {
          kind: "recovered",
          message: `${host} is reachable again${ip ? ` (${ip})` : ""}. Down since ${prev.since}.`,
        },
      };
    }
    return { state: { ...prev, failures: 0, ip }, alert: null };
  }

  const failures = prev.failures + 1;
  if (prev.status === "up" && failures >= FAILURES_BEFORE_DOWN) {
    const ipText = result.ip ? `resolves to ${result.ip}` : "does not resolve";
    return {
      state: { status: "down", failures, ip, since: now },
      alert: {
        kind: "down",
        message: `${host} is DOWN: ${result.error ?? "connection failed"}. DNS ${ipText}.`,
      },
    };
  }
  return { state: { ...prev, failures, ip }, alert: null };
}
