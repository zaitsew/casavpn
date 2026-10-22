// The cron side of the relay: the stored monitor state, and what a state change
// does (an alert in the history, a push, optionally ntfy). The TCP and DNS probes
// live in index.ts because they need cloudflare:sockets; this file runs under
// `node --test`.

import { raiseAlert, type Deps, type RelayEnv } from "./relay.ts";
import { STATE_KEY, loadState, targetOf, type StoredState } from "./state.ts";
import { initialState, transition, type CheckResult } from "./transition.ts";

export interface MonitorEnv extends RelayEnv {
  /** Secret, optional: the full ntfy topic URL, e.g. https://ntfy.sh/casavpn-<random>. */
  NTFY_URL?: string;
}

/** ntfy is a second channel: a failure is logged and never stops the state change. */
async function notifyNtfy(env: MonitorEnv, deps: Deps, kind: string, body: string): Promise<void> {
  if (!env.NTFY_URL) return;
  const down = kind === "vpn.down";
  try {
    // Header values must be plain ASCII.
    const res = await deps.fetch(env.NTFY_URL, {
      method: "POST",
      body,
      headers: {
        Title: down ? "CasaVPN is DOWN" : "CasaVPN recovered",
        Priority: down ? "urgent" : "default",
        Tags: down ? "rotating_light" : "white_check_mark",
      },
    });
    if (!res.ok) console.log(JSON.stringify({ ntfy: "rejected", status: res.status }));
  } catch (e) {
    console.log(JSON.stringify({ ntfy: "failed", error: e instanceof Error ? e.message : String(e) }));
  }
}

/** Feeds one probe result to the state machine; records and pushes a transition. */
export async function applyCheck(env: MonitorEnv, deps: Deps, result: CheckResult): Promise<StoredState> {
  const now = new Date(deps.now()).toISOString();
  const target = targetOf(env);
  const prev = (await loadState(env.STATE)) ?? initialState(now);
  const { state, alert } = transition(prev, result, now, target);

  if (alert) {
    const kind = alert.kind === "down" ? "vpn.down" : "vpn.recovered";
    const event = {
      kind,
      severity: alert.kind === "down" ? ("critical" as const) : ("info" as const),
      title: alert.kind === "down" ? "CasaVPN is down" : "CasaVPN is back",
      body: alert.message.slice(0, 400),
    };
    // If the state write below fails, the next run reaches the same transition
    // from the same previous state. The key (kind + when that state began) is
    // the same, so the alert is recorded once.
    const recorded = await raiseAlert(env, deps, event, "monitor", `monitor:${kind}:${prev.since}`);
    if (recorded) await notifyNtfy(env, deps, kind, alert.message);
  }
  // One write a run (288 a day) keeps `lastCheck` honest; the free plan allows 1000.
  const next: StoredState = { ...state, lastCheck: now, target };
  await env.STATE.put(STATE_KEY, JSON.stringify(next));
  console.log(
    JSON.stringify({ target, ok: result.ok, ip: result.ip, status: state.status, failures: state.failures, alert: alert?.kind ?? null }),
  );
  return next;
}
