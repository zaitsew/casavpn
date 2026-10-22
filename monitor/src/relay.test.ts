import test from "node:test";
import assert from "node:assert/strict";
import { handle, raiseAlert } from "./relay.ts";
import { resetJwtCache } from "./apns.ts";
import { APP, HOST, NOW, TOKEN_A, TOKEN_B, fakeFetch, makeEnv, makeKey } from "./testutil.ts";
import type { Alert, Device } from "./store.ts";

const BASE = "https://relay.example.com";

function req(method: string, path: string, opts: { token?: string | null; body?: unknown; raw?: string } = {}): Request {
  const headers: Record<string, string> = {};
  if (opts.token !== null) headers.authorization = `Bearer ${opts.token ?? APP}`;
  const body = opts.raw ?? (opts.body === undefined ? undefined : JSON.stringify(opts.body));
  return new Request(BASE + path, { method, headers, body });
}

function setup(extra = {}) {
  const env = makeEnv(extra);
  const f = fakeFetch();
  let now = NOW;
  const deps = { fetch: f.fn, now: () => now };
  return {
    env,
    f,
    tick: (ms: number) => (now += ms),
    call: (r: Request) => handle(r, env, deps),
  };
}

const event = { kind: "ip.changed", severity: "warning" as const, title: "IP changed", body: "198.51.100.7 -> 198.51.100.8" };

test("unknown routes are 404, wrong methods 405 with Allow", async () => {
  const { call } = setup();
  assert.equal((await call(req("GET", "/"))).status, 404);
  assert.equal((await call(req("GET", "/v1/nothing"))).status, 404);
  assert.equal((await call(req("GET", "/v1/constructor"))).status, 404);
  assert.equal((await call(req("GET", "/v1/alerts/extra"))).status, 404);
  assert.equal((await call(req("POST", "/v1/devices/abc/def"))).status, 404);
  const r = await call(req("POST", "/v1/alerts"));
  assert.equal(r.status, 405);
  assert.equal(r.headers.get("allow"), "GET");
  assert.equal((await call(req("GET", "/v1/events"))).status, 405);
  assert.equal((await call(req("PUT", "/v1/devices"))).status, 405);
  assert.equal((await call(req("GET", `/v1/devices/${TOKEN_A}`))).status, 405);
});

test("bad or missing credentials get 401 with an empty body", async () => {
  const { call } = setup();
  for (const token of [null, "", "wrong", HOST]) {
    const r = await call(req("GET", "/v1/alerts", { token }));
    assert.equal(r.status, 401, String(token));
    assert.equal(await r.text(), "");
  }
  // The host token cannot do the app's work, nor the other way round.
  assert.equal((await call(req("POST", "/v1/test", { token: HOST }))).status, 401);
  assert.equal((await call(req("POST", "/v1/events", { token: APP, body: event }))).status, 401);
  // Wrong scheme, and a prefix of the right token.
  const basic = new Request(BASE + "/v1/alerts", { headers: { authorization: `Basic ${APP}` } });
  assert.equal((await call(basic)).status, 401);
  assert.equal((await call(req("GET", "/v1/alerts", { token: APP.slice(0, -1) }))).status, 401);
});

test("unset secrets fail closed", async () => {
  const { call } = setup({ APP_TOKEN: undefined, HOST_TOKEN: "" });
  assert.equal((await call(req("GET", "/v1/alerts", { token: "" }))).status, 401);
  assert.equal((await call(req("GET", "/v1/alerts", { token: "undefined" }))).status, 401);
  assert.equal((await call(req("POST", "/v1/events", { token: "", body: event }))).status, 401);
});

test("POST /v1/devices stores a lowercase token; DELETE removes it", async () => {
  const { call, env } = setup();
  const r = await call(req("POST", "/v1/devices", { body: { token: "A".repeat(64), environment: "sandbox", name: "Test phone" } }));
  assert.equal(r.status, 204);
  const devices = env.STATE.json<Device[]>("devices");
  assert.equal(devices.length, 1);
  assert.equal(devices[0]!.token, TOKEN_A);
  assert.equal(devices[0]!.environment, "sandbox");
  assert.equal((await call(req("DELETE", `/v1/devices/${TOKEN_A}`))).status, 204);
  assert.deepEqual(env.STATE.json<Device[]>("devices"), []);
  // Deleting an unknown token is not an error and writes nothing.
  const puts = env.STATE.puts.length;
  assert.equal((await call(req("DELETE", `/v1/devices/${TOKEN_B}`))).status, 204);
  assert.equal(env.STATE.puts.length, puts);
  assert.equal((await call(req("DELETE", "/v1/devices/not-hex"))).status, 400);
});

test("registering a device again refreshes it and moves it to the newest slot", async () => {
  const { call, env, tick } = setup();
  const body = { token: TOKEN_A, environment: "production", name: "Phone" };
  await call(req("POST", "/v1/devices", { body }));
  await call(req("POST", "/v1/devices", { body: { token: TOKEN_B, environment: "production", name: "Other" } }));
  tick(60_000);
  await call(req("POST", "/v1/devices", { body: { ...body, name: "Renamed" } }));
  const devices = env.STATE.json<Device[]>("devices");
  assert.deepEqual(devices.map((d) => [d.token, d.name]), [[TOKEN_B, "Other"], [TOKEN_A, "Renamed"]]);
  assert.equal(devices[1]!.addedAt, "2026-10-22T12:01:00.000Z");
});

test("a phone that re-registers with 10 devices stored is not the one evicted", async () => {
  const { call, env } = setup();
  const tokens = Array.from({ length: 10 }, (_, i) => i.toString(16).padStart(2, "0").repeat(32));
  for (const token of tokens) await call(req("POST", "/v1/devices", { body: { token, environment: "production", name: "d" } }));
  await call(req("POST", "/v1/devices", { body: { token: tokens[0], environment: "production", name: "d" } }));
  await call(req("POST", "/v1/devices", { body: { token: TOKEN_A, environment: "production", name: "new" } }));
  const kept = env.STATE.json<Device[]>("devices").map((d) => d.token);
  assert.equal(kept.length, 10);
  assert.ok(kept.includes(tokens[0]!), "the refreshed phone stays");
  assert.ok(!kept.includes(tokens[1]!), "the oldest untouched one goes");
});

test("at most 10 devices: the oldest is dropped", async () => {
  const { call, env, tick } = setup();
  for (let i = 0; i < 12; i++) {
    tick(1000);
    const token = i.toString(16).padStart(2, "0").repeat(32);
    assert.equal((await call(req("POST", "/v1/devices", { body: { token, environment: "production", name: `d${i}` } }))).status, 204);
  }
  const devices = env.STATE.json<Device[]>("devices");
  assert.equal(devices.length, 10);
  assert.deepEqual(devices.map((d) => d.name), ["d2", "d3", "d4", "d5", "d6", "d7", "d8", "d9", "d10", "d11"]);
});

test("device validation", async () => {
  const { call, env } = setup();
  const ok = { token: TOKEN_A, environment: "production", name: "Phone" };
  const cases: unknown[] = [
    { ...ok, token: "xyz" },
    { ...ok, token: "ab" },
    { ...ok, token: "a".repeat(201) },
    { ...ok, environment: "staging" },
    { ...ok, name: "" },
    { ...ok, name: "n".repeat(41) },
    { ...ok, name: "bad\u0000name" },
    { ...ok, extra: 1 },
    { token: TOKEN_A },
    [],
    "text",
    null,
  ];
  for (const body of cases) {
    const r = await call(req("POST", "/v1/devices", { body }));
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.ok(typeof (await r.json() as { error: string }).error === "string");
  }
  assert.equal((await call(req("POST", "/v1/devices", { raw: "{not json" }))).status, 400);
  assert.equal(env.STATE.data.has("devices"), false);
  // The limits themselves are valid.
  assert.equal((await call(req("POST", "/v1/devices", { body: { ...ok, name: "n".repeat(40) } }))).status, 204);
});

test("bodies over 4 KB are refused with 413", async () => {
  const { call, env } = setup();
  const big = { ...event, body: "x".repeat(5000) };
  assert.equal((await call(req("POST", "/v1/events", { token: HOST, body: big }))).status, 413);
  // Without a content-length header (chunked) the cap still holds.
  const stream = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode("x".repeat(3000)));
      c.enqueue(new TextEncoder().encode("x".repeat(3000)));
      c.close();
    },
  });
  const chunked = new Request(BASE + "/v1/events", { method: "POST", headers: { authorization: `Bearer ${HOST}` }, body: stream, duplex: "half" } as RequestInit);
  assert.equal((await call(chunked)).status, 413);
  assert.equal(env.STATE.alerts().length, 0);
});

test("event validation", async () => {
  const { call, env } = setup();
  const cases: unknown[] = [
    { ...event, kind: "Bad Kind" },
    { ...event, kind: "" },
    { ...event, kind: "k".repeat(33) },
    { ...event, kind: "cert-expiring" },
    { ...event, severity: "fatal" },
    { ...event, title: "" },
    { ...event, title: "t".repeat(81) },
    { ...event, body: "b".repeat(401) },
    { ...event, dedupe: "" },
    { ...event, dedupe: "d".repeat(65) },
    { ...event, dedupe: 5 },
    { ...event, source: "app" },
    { kind: "x" },
    [],
  ];
  for (const body of cases) {
    assert.equal((await call(req("POST", "/v1/events", { token: HOST, body }))).status, 400, JSON.stringify(body));
  }
  assert.equal(env.STATE.alerts().length, 0);
  const edge = { kind: "a".repeat(32), severity: "info", title: "t".repeat(80), body: "b".repeat(400), dedupe: "d".repeat(64) };
  assert.equal((await call(req("POST", "/v1/events", { token: HOST, body: edge }))).status, 202);
  assert.equal((await call(req("POST", "/v1/events", { token: HOST, body: { ...event, body: "" } }))).status, 202);
});

test("POST /v1/events stores the alert and answers 202 with id and pushed", async () => {
  const { call, env, tick } = setup();
  tick(5000);
  const r = await call(req("POST", "/v1/events", { token: HOST, body: event }));
  assert.equal(r.status, 202);
  const answer = (await r.json()) as { id: string; pushed: number };
  assert.equal(answer.pushed, 0);
  const alerts = env.STATE.alerts();
  assert.equal(alerts.length, 1);
  assert.deepEqual(alerts[0], {
    id: answer.id,
    at: "2026-10-22T12:00:05.000Z",
    source: "host",
    kind: "ip.changed",
    severity: "warning",
    title: "IP changed",
    body: "198.51.100.7 -> 198.51.100.8",
  });
});

test("dedupe: a repeated key within 6 hours is stored and pushed nowhere", async () => {
  const { call, env } = setup();
  const e = { ...event, dedupe: "cert.expiring:2026-12-30" };
  assert.equal((await call(req("POST", "/v1/events", { token: HOST, body: e }))).status, 202);
  assert.equal(env.STATE.ttls.get("dedupe:cert.expiring:2026-12-30"), 21600);
  const again = await call(req("POST", "/v1/events", { token: HOST, body: e }));
  assert.equal(again.status, 200);
  assert.deepEqual(await again.json(), { deduped: true });
  assert.equal(env.STATE.alerts().length, 1);
  // Another key, and an event without a key, both go through.
  assert.equal((await call(req("POST", "/v1/events", { token: HOST, body: { ...e, dedupe: "other" } }))).status, 202);
  assert.equal((await call(req("POST", "/v1/events", { token: HOST, body: event }))).status, 202);
  assert.equal((await call(req("POST", "/v1/events", { token: HOST, body: event }))).status, 202);
  assert.equal(env.STATE.alerts().length, 4);
});

test("every alert is its own key, with a 30-day expiry; a read returns the newest 100", async () => {
  const { env, f, call } = setup();
  let now = NOW;
  const deps = { fetch: f.fn, now: () => now };
  for (let i = 0; i < 105; i++) {
    now += 1;
    await raiseAlert(env, deps, { ...event, title: `n${i}` }, "host");
  }
  assert.equal(env.STATE.data.has("alerts"), false, "no shared history key");
  const keys = [...env.STATE.data.keys()].filter((k) => k.startsWith("alert:"));
  assert.equal(keys.length, 105);
  assert.ok(keys.every((k) => /^alert:\d{13}-[0-9a-f]{6}$/.test(k)));
  assert.ok(keys.every((k) => env.STATE.ttls.get(k) === 30 * 86400));
  const body = (await (await call(req("GET", "/v1/alerts?limit=100"))).json()) as { alerts: Alert[] };
  assert.equal(body.alerts.length, 100);
  assert.equal(body.alerts[0]!.title, "n104");
  assert.equal(body.alerts[99]!.title, "n5");
});

test("two alerts raised at the same moment both survive", async () => {
  const { env, f } = setup();
  const deps = { fetch: f.fn, now: () => NOW };
  await Promise.all(Array.from({ length: 20 }, (_, i) => raiseAlert(env, deps, { ...event, title: `n${i}` }, "host")));
  assert.equal(env.STATE.alerts().length, 20);
});

test("an alert that would overflow KV's 1 KB metadata is shortened, not refused", async () => {
  const { call, env } = setup();
  const wide = { ...event, title: "\u00e9".repeat(80), body: "\u4e2d".repeat(400) };
  assert.equal((await call(req("POST", "/v1/events", { token: HOST, body: wide }))).status, 202);
  const [a] = env.STATE.alerts();
  assert.ok(new TextEncoder().encode(JSON.stringify(a)).length <= 1000);
  assert.ok(a!.body.length > 0 && a!.body.length < 400);
  assert.equal(a!.kind, "ip.changed");
});

test("alert ids sort by time", async () => {
  const { env, f } = setup();
  let now = NOW;
  const deps = { fetch: f.fn, now: () => now };
  const ids: string[] = [];
  for (let i = 0; i < 5; i++) {
    now += 1;
    ids.push((await raiseAlert(env, deps, event, "host"))!.alert.id);
  }
  assert.deepEqual([...ids].sort(), ids);
  assert.equal(new Set(ids).size, 5);
});

test("GET /v1/alerts returns newest first, honours limit, includes the monitor", async () => {
  const { call, env, tick } = setup();
  for (let i = 0; i < 5; i++) {
    tick(1000);
    await call(req("POST", "/v1/events", { token: HOST, body: { ...event, title: `n${i}` } }));
  }
  let body = (await (await call(req("GET", "/v1/alerts"))).json()) as { alerts: Alert[]; monitor: Record<string, unknown> };
  assert.deepEqual(body.alerts.map((a) => a.title), ["n4", "n3", "n2", "n1", "n0"]);
  assert.deepEqual(body.monitor, { status: "unknown", since: null, lastCheck: null, ip: null, target: "vpn.example.com:443" });
  body = (await (await call(req("GET", "/v1/alerts?limit=2"))).json()) as typeof body;
  assert.deepEqual(body.alerts.map((a) => a.title), ["n4", "n3"]);

  await env.STATE.put("state", JSON.stringify({ status: "down", failures: 2, ip: "198.51.100.10", since: "2026-10-22T11:00:00.000Z", lastCheck: "2026-10-22T11:55:00.000Z", target: "vpn.example.com:443" }));
  body = (await (await call(req("GET", "/v1/alerts"))).json()) as typeof body;
  assert.deepEqual(body.monitor, { status: "down", since: "2026-10-22T11:00:00.000Z", lastCheck: "2026-10-22T11:55:00.000Z", ip: "198.51.100.10", target: "vpn.example.com:443" });
});

test("GET /v1/alerts rejects a bad limit", async () => {
  const { call } = setup();
  for (const q of ["0", "101", "-1", "abc", "1.5", ""]) {
    assert.equal((await call(req("GET", `/v1/alerts?limit=${q}`))).status, 400, q);
  }
  assert.equal((await call(req("GET", "/v1/alerts?limit=100"))).status, 200);
  assert.equal((await call(req("GET", "/v1/alerts?limit=1"))).status, 200);
});

test("POST /v1/test records a test alert from the app", async () => {
  const { call, env } = setup();
  const r = await call(req("POST", "/v1/test"));
  assert.equal(r.status, 202);
  const answer = (await r.json()) as { id: string; pushed: number };
  const [alert] = env.STATE.alerts();
  assert.equal(alert!.id, answer.id);
  assert.equal(alert!.kind, "test");
  assert.equal(alert!.source, "app");
  assert.equal(alert!.severity, "info");
});

test("with APNs configured, an event is pushed to every device and dead tokens are removed", async () => {
  resetJwtCache();
  const key = await makeKey();
  const f = fakeFetch((c) => {
    if (c.url.includes(TOKEN_B)) return Response.json({ reason: "BadDeviceToken" }, { status: 400 });
    return new Response("", { status: 200 });
  });
  const env = makeEnv({ APNS_KEY_P8: key.pem, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234", APNS_TOPIC: "com.example.casavpn" });
  const deps = { fetch: f.fn, now: () => NOW };
  await handle(req("POST", "/v1/devices", { body: { token: TOKEN_A, environment: "production", name: "A" } }), env, deps);
  await handle(req("POST", "/v1/devices", { body: { token: TOKEN_B, environment: "sandbox", name: "B" } }), env, deps);
  const r = await handle(req("POST", "/v1/events", { token: HOST, body: event }), env, deps);
  assert.equal(r.status, 202);
  assert.equal(((await r.json()) as { pushed: number }).pushed, 1);
  assert.equal(f.calls.length, 2);
  assert.deepEqual(env.STATE.json<Device[]>("devices").map((d) => d.token), [TOKEN_A]);
  // The alert is in the history whatever APNs said.
  assert.equal(env.STATE.alerts().length, 1);
});
