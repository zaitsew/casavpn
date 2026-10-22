// The relay API of docs/APP.md: devices, alert history, events from the host,
// and the pushes they cause. `handle` takes its dependencies (KV, fetch, clock)
// as arguments, so tests run it without Cloudflare.

import { apnsConfigured, sendPush, type ApnsDeps, type ApnsEnv } from "./apns.ts";
import { bearerMatches } from "./auth.ts";
import { monitorView, type TargetEnv } from "./state.ts";
import {
  addAlert,
  addDevice,
  isDeduped,
  loadAlerts,
  loadDevices,
  markDeduped,
  newAlertId,
  removeDevices,
  type Alert,
  type Event,
  type Source,
} from "./store.ts";
import { DEVICE_TOKEN_RE, MAX_BODY_BYTES, parseDevice, parseEvent } from "./validate.ts";

export type Deps = ApnsDeps;

export interface RelayEnv extends ApnsEnv, TargetEnv {
  /** Secret: the app's bearer token. */
  APP_TOKEN?: string;
  /** Secret: the host scripts' bearer token. */
  HOST_TOKEN?: string;
}

/**
 * Records an alert and pushes it to every device. Returns null when `dedupeKey`
 * was seen in the last 6 hours: nothing is stored and nothing is pushed.
 * The history write comes before the marker and the push: a crash between them
 * can repeat an alert, never lose one.
 */
export async function raiseAlert(
  env: RelayEnv,
  deps: Deps,
  event: Omit<Event, "dedupe">,
  source: Source,
  dedupeKey?: string,
): Promise<{ alert: Alert; pushed: number } | null> {
  if (dedupeKey && (await isDeduped(env.STATE, dedupeKey))) return null;
  const nowMs = deps.now();
  const alert: Alert = {
    id: newAlertId(nowMs),
    at: new Date(nowMs).toISOString(),
    source,
    kind: event.kind,
    severity: event.severity,
    title: event.title,
    body: event.body,
  };
  await addAlert(env.STATE, alert);
  if (dedupeKey) await markDeduped(env.STATE, dedupeKey);

  let pushed = 0;
  if (apnsConfigured(env)) {
    const devices = await loadDevices(env.STATE);
    const result = await sendPush(env, devices, alert, deps);
    pushed = result.pushed;
    await removeDevices(env.STATE, result.invalid);
  }
  return { alert, pushed };
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
const empty = (status: number): Response => new Response(null, { status });
const bad = (error: string): Response => json(400, { error });

/** Reads at most MAX_BODY_BYTES; a longer body is refused without being read to the end. */
async function readBody(request: Request): Promise<string | Response> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) return json(413, { error: "body too large" });
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) {
      await reader.cancel();
      return json(413, { error: "body too large" });
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder().decode(all);
}

async function readJson(request: Request): Promise<{ value: unknown } | Response> {
  const text = await readBody(request);
  if (text instanceof Response) return text;
  try {
    return { value: JSON.parse(text) };
  } catch {
    return bad("body must be JSON");
  }
}

type Who = "app" | "host";
interface Route {
  method: string;
  who: Who;
  run: (request: Request, env: RelayEnv, deps: Deps, rest: string) => Promise<Response>;
}

const routes: Record<string, Route> = {
  devices: {
    method: "POST",
    who: "app",
    async run(request, env, deps) {
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const parsed = parseDevice(body.value);
      if (!parsed.ok) return bad(parsed.error);
      await addDevice(env.STATE, { ...parsed.value, addedAt: new Date(deps.now()).toISOString() });
      return empty(204);
    },
  },
  alerts: {
    method: "GET",
    who: "app",
    async run(request, env) {
      const raw = new URL(request.url).searchParams.get("limit");
      let limit = 50;
      if (raw !== null) {
        if (!/^\d{1,3}$/.test(raw) || Number(raw) < 1 || Number(raw) > 100) return bad("limit must be 1-100");
        limit = Number(raw);
      }
      const [alerts, monitor] = await Promise.all([loadAlerts(env.STATE), monitorView(env)]);
      return json(200, { alerts: alerts.slice(0, limit), monitor });
    },
  },
  events: {
    method: "POST",
    who: "host",
    async run(request, env, deps) {
      const body = await readJson(request);
      if (body instanceof Response) return body;
      const parsed = parseEvent(body.value);
      if (!parsed.ok) return bad(parsed.error);
      const { dedupe, ...event } = parsed.value;
      const raised = await raiseAlert(env, deps, event, "host", dedupe);
      if (!raised) return json(200, { deduped: true });
      return json(202, { id: raised.alert.id, pushed: raised.pushed });
    },
  },
  test: {
    method: "POST",
    who: "app",
    async run(_request, env, deps) {
      const raised = await raiseAlert(env, deps, { kind: "test", severity: "info", title: "Test alert", body: "Push notifications from the CasaVPN relay work." }, "app");
      return json(202, { id: raised!.alert.id, pushed: raised!.pushed });
    },
  },
};

const deviceRoute: Route = {
  method: "DELETE",
  who: "app",
  async run(_request, env, _deps, rest) {
    if (!DEVICE_TOKEN_RE.test(rest)) return bad("token must be hex");
    await removeDevices(env.STATE, [rest.toLowerCase()]);
    return empty(204);
  },
};

export async function handle(request: Request, env: RelayEnv, deps: Deps): Promise<Response> {
  const url = new URL(request.url);
  const m = /^\/v1\/([a-z]+)(?:\/([^/]+))?$/.exec(url.pathname);
  let route: Route | undefined;
  let rest = "";
  if (m && m[2] === undefined) route = Object.hasOwn(routes, m[1]!) ? routes[m[1]!] : undefined;
  else if (m && m[1] === "devices") {
    route = deviceRoute;
    rest = m[2]!;
  }
  if (!route) return empty(404);
  if (request.method !== route.method) {
    return new Response(null, { status: 405, headers: { allow: route.method } });
  }
  const secret = route.who === "app" ? env.APP_TOKEN : env.HOST_TOKEN;
  if (!(await bearerMatches(request, secret))) {
    return new Response(null, { status: 401, headers: { "www-authenticate": "Bearer" } });
  }
  return route.run(request, env, deps, rest);
}
