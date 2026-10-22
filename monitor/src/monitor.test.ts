import test from "node:test";
import assert from "node:assert/strict";
import { applyCheck } from "./monitor.ts";
import { resetJwtCache } from "./apns.ts";
import { NOW, TOKEN_A, fakeFetch, makeEnv, makeKey } from "./testutil.ts";
import type { Alert } from "./store.ts";
import type { StoredState } from "./state.ts";
import type { CheckResult } from "./transition.ts";

const ok: CheckResult = { ok: true, ip: "198.51.100.10" };
const fail: CheckResult = { ok: false, ip: "198.51.100.10", error: "connect timeout" };
const quiet = async <T>(fn: () => Promise<T>): Promise<T> => {
  const log = console.log;
  console.log = () => {};
  try {
    return await fn();
  } finally {
    console.log = log;
  }
};

function setup(extra = {}) {
  const env = makeEnv(extra);
  const f = fakeFetch();
  let now = NOW;
  const deps = { fetch: f.fn, now: () => now };
  return { env, f, deps, tick: (ms = 300_000) => (now += ms), run: (r: CheckResult) => quiet(() => applyCheck(env, deps, r)) };
}

const alertsOf = (env: ReturnType<typeof makeEnv>) => (env.STATE.json<Alert[]>("alerts") ?? []).map((a) => a.kind);

test("two failures raise vpn.down once, recovery raises vpn.recovered once", async () => {
  const { env, run, tick } = setup();
  await run(ok);
  tick();
  await run(fail);
  assert.deepEqual(alertsOf(env), []);
  tick();
  await run(fail);
  assert.deepEqual(alertsOf(env), ["vpn.down"]);
  const [down] = env.STATE.json<Alert[]>("alerts");
  assert.equal(down!.severity, "critical");
  assert.equal(down!.source, "monitor");
  assert.equal(down!.title, "CasaVPN is down");
  assert.match(down!.body, /vpn\.example\.com:443 is DOWN: connect timeout/);
  // Still down: no repeat.
  tick();
  await run(fail);
  tick();
  await run(fail);
  assert.deepEqual(alertsOf(env), ["vpn.down"]);
  tick();
  await run(ok);
  assert.deepEqual(alertsOf(env), ["vpn.recovered", "vpn.down"]);
  assert.equal(env.STATE.json<Alert[]>("alerts")[0]!.severity, "info");
});

test("the state records lastCheck and target on every run", async () => {
  const { env, run, tick } = setup();
  await run(ok);
  tick();
  const s = await run(ok);
  assert.equal(s.lastCheck, "2026-10-22T12:05:00.000Z");
  const stored = env.STATE.json<StoredState>("state");
  assert.equal(stored.target, "vpn.example.com:443");
  assert.equal(stored.lastCheck, "2026-10-22T12:05:00.000Z");
  assert.equal(stored.status, "up");
});

test("a retry after a failed state write records the transition once", async () => {
  const { env, run, tick } = setup();
  await run(ok);
  tick();
  await run(fail);
  tick();
  env.STATE.failPutsFor = "state";
  await assert.rejects(run(fail), /KV put failed/);
  // The alert is in the history, the state is still "up, 1 failure".
  assert.deepEqual(alertsOf(env), ["vpn.down"]);
  assert.equal(env.STATE.json<StoredState>("state").status, "up");
  // Next run: same transition from the same previous state, no second record.
  env.STATE.failPutsFor = null;
  tick();
  await run(fail);
  assert.deepEqual(alertsOf(env), ["vpn.down"]);
  assert.equal(env.STATE.json<StoredState>("state").status, "down");
  // Recovery after that is a new transition and is recorded.
  tick();
  await run(ok);
  assert.deepEqual(alertsOf(env), ["vpn.recovered", "vpn.down"]);
});

test("a retry does not push again either", async () => {
  resetJwtCache();
  const key = await makeKey();
  const { env, f, run, tick } = setup({ APNS_KEY_P8: key.pem, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234", APNS_TOPIC: "com.example.casavpn" });
  await env.STATE.put("devices", JSON.stringify([{ token: TOKEN_A, environment: "production", name: "A", addedAt: "x" }]));
  await run(ok);
  await run(fail);
  env.STATE.failPutsFor = "state";
  await assert.rejects(run(fail), /KV put failed/);
  assert.equal(f.calls.length, 1);
  assert.match(f.calls[0]!.url, /api\.push\.apple\.com/);
  env.STATE.failPutsFor = null;
  tick();
  await run(fail);
  assert.equal(f.calls.length, 1);
  const body = JSON.parse(f.calls[0]!.init.body as string);
  assert.equal(body.kind, "vpn.down");
  assert.equal(body.aps["interruption-level"], "time-sensitive");
});

test("ntfy is optional: no NTFY_URL means no request", async () => {
  const { f, run } = setup();
  await run(fail);
  await run(fail);
  assert.equal(f.calls.length, 0);
});

test("with NTFY_URL set, a transition also posts to ntfy", async () => {
  const { f, run, tick } = setup({ NTFY_URL: "https://ntfy.example.com/casavpn-test" });
  await run(fail);
  tick();
  await run(fail);
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0]!.url, "https://ntfy.example.com/casavpn-test");
  const h = f.calls[0]!.init.headers as Record<string, string>;
  assert.equal(h.Title, "CasaVPN is DOWN");
  assert.equal(h.Priority, "urgent");
});

test("an ntfy failure is logged, never thrown, and the state still changes", async () => {
  for (const respond of [() => new Response("", { status: 522 }), () => { throw new Error("ntfy unreachable"); }]) {
    const env = makeEnv({ NTFY_URL: "https://ntfy.example.com/casavpn-test" });
    const f = fakeFetch(respond);
    const deps = { fetch: f.fn, now: () => NOW };
    await quiet(() => applyCheck(env, deps, fail));
    const s = await quiet(() => applyCheck(env, deps, fail));
    assert.equal(s.status, "down");
    assert.equal(env.STATE.json<StoredState>("state").status, "down");
    assert.deepEqual(alertsOf(env), ["vpn.down"]);
  }
});
