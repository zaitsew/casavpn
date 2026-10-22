// CasaVPN external uptime monitor and alert relay: a Cloudflare Worker.
//
// On a 5-minute cron it
//   1. resolves vpn.example.com through DNS-over-HTTPS (to report where DNS points),
//   2. opens a TCP connection to vpn.example.com:443 (the Reality listener),
//   3. feeds the result to the state machine in transition.ts, and
//   4. on a state change (down after two failures in a row, and recovered)
//      records an alert and pushes it to the iPhone app over APNs (monitor.ts).
//
// On HTTPS it serves the relay API of docs/APP.md (relay.ts): the app registers
// its device and reads the alert history; the host scripts post events.
//
// It runs on Cloudflare's network, not in the house, so it still reports when
// the Pi or the home connection is dead. State lives in KV.

import { connect } from "cloudflare:sockets";
import { applyCheck, type MonitorEnv } from "./monitor.ts";
import { handle, type Deps } from "./relay.ts";
import type { CheckResult } from "./transition.ts";

export type Env = MonitorEnv & { STATE: KVNamespace };

const CONNECT_TIMEOUT_MS = 8000;

const deps = (): Deps => ({ fetch: (input, init) => fetch(input, init), now: () => Date.now() });

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

export async function runCheck(env: Env): Promise<void> {
  // No default on purpose: a monitor pointed at a placeholder would report
  // "up" or "down" about somebody else's host.
  if (!env.TARGET_HOST) throw new Error("TARGET_HOST is not set (wrangler.toml, [vars])");
  const result = await check(env.TARGET_HOST, Number(env.TARGET_PORT ?? "443"));
  await applyCheck(env, deps(), result);
}

export default {
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runCheck(env));
  },
  async fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, deps());
  },
} satisfies ExportedHandler<Env>;
