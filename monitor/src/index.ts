// CasaVPN external uptime monitor: a Cloudflare Worker on a 5-minute cron.
//
// Every run it
//   1. resolves vpn.example.com through DNS-over-HTTPS (to report where DNS points),
//   2. opens a TCP connection to vpn.example.com:443 (the Reality listener),
//   3. feeds the result to the state machine in transition.ts, and
//   4. pushes to ntfy only when the state changes: down after two failures in a
//      row, and recovered.
//
// It runs on Cloudflare's network, not in the house, so it still reports when
// the Pi or the home connection is dead. State lives in one KV key.

import { connect } from "cloudflare:sockets";
import { initialState, transition, type Alert, type CheckResult, type MonitorState } from "./transition.ts";

export interface Env {
  STATE: KVNamespace;
  /** Secret: the full ntfy topic URL, e.g. https://ntfy.sh/casavpn-<random>. */
  NTFY_URL: string;
  TARGET_HOST?: string;
  TARGET_PORT?: string;
}

const STATE_KEY = "state";
const CONNECT_TIMEOUT_MS = 8000;

/** First A record for `host` according to Cloudflare's DoH resolver, or null. */
export async function resolveA(host: string): Promise<string | null> {
  const url = `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(host)}&type=A`;
  const res = await fetch(url, { headers: { accept: "application/dns-json" } });
  if (!res.ok) return null;
  const body = (await res.json()) as { Answer?: { type: number; data: string }[] };
  return body.Answer?.find((a) => a.type === 1)?.data ?? null;
}

/** Opens (and closes) a TCP connection. Returns an error string on failure. */
async function tcpProbe(hostname: string, port: number): Promise<string | null> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const socket = connect({ hostname, port });
  try {
    await Promise.race([
      socket.opened,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`connect timeout after ${CONNECT_TIMEOUT_MS / 1000}s`)), CONNECT_TIMEOUT_MS);
      }),
    ]);
    return null;
  } catch (e) {
    return e instanceof Error ? e.message : String(e);
  } finally {
    clearTimeout(timer);
    try {
      await socket.close();
    } catch {
      // already closed or never opened
    }
  }
}

async function check(host: string, port: number): Promise<CheckResult> {
  let ip: string | null = null;
  try {
    ip = await resolveA(host);
  } catch {
    // The DoH lookup is informational; the TCP probe decides up or down.
  }
  const error = await tcpProbe(host, port);
  return error === null ? { ok: true, ip } : { ok: false, ip, error };
}

async function notify(env: Env, alert: Alert): Promise<void> {
  // Header values must be plain ASCII.
  const res = await fetch(env.NTFY_URL, {
    method: "POST",
    body: alert.message,
    headers: {
      Title: alert.kind === "down" ? "CasaVPN is DOWN" : "CasaVPN recovered",
      Priority: alert.kind === "down" ? "urgent" : "default",
      Tags: alert.kind === "down" ? "rotating_light" : "white_check_mark",
    },
  });
  if (!res.ok) throw new Error(`ntfy answered ${res.status}`);
}

async function loadState(env: Env, now: string): Promise<MonitorState> {
  const raw = await env.STATE.get(STATE_KEY);
  if (!raw) return initialState(now);
  try {
    return JSON.parse(raw) as MonitorState;
  } catch {
    return initialState(now);
  }
}

export async function runCheck(env: Env): Promise<void> {
  // No default on purpose: a monitor pointed at a placeholder would report
  // "up" or "down" about somebody else's host.
  if (!env.TARGET_HOST) throw new Error("TARGET_HOST is not set (wrangler.toml, [vars])");
  const host = env.TARGET_HOST;
  const port = Number(env.TARGET_PORT ?? "443");
  const now = new Date().toISOString();

  const prev = await loadState(env, now);
  const result = await check(host, port);
  const { state, alert } = transition(prev, result, now, `${host}:${port}`);

  if (alert) {
    // If ntfy is unreachable we keep the old state, so the next run reaches the
    // same conclusion and tries again instead of swallowing the alert.
    await notify(env, alert);
  }
  // KV free tier allows 1000 writes a day: write only when something changed.
  if (JSON.stringify(state) !== JSON.stringify(prev)) {
    await env.STATE.put(STATE_KEY, JSON.stringify(state));
  }
  console.log(JSON.stringify({ host, port, ok: result.ok, ip: result.ip, status: state.status, failures: state.failures, alert: alert?.kind ?? null }));
}

export default {
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runCheck(env));
  },
} satisfies ExportedHandler<Env>;
