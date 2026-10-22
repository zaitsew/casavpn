import test from "node:test";
import assert from "node:assert/strict";
import { getJwt, payloadFor, resetJwtCache, sendPush, signJwt } from "./apns.ts";
import { NOW, TOKEN_A, TOKEN_B, fakeFetch, makeKey, pem } from "./testutil.ts";
import type { Alert, Device } from "./store.ts";

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(s.length / 4) * 4, "=");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}
const decodeJson = (s: string) => JSON.parse(new TextDecoder().decode(b64urlToBytes(s))) as Record<string, unknown>;

const alert: Alert = {
  id: "00a1b2c3d4e5-abcdef",
  at: "2026-10-22T12:00:00.000Z",
  source: "monitor",
  kind: "vpn.down",
  severity: "critical",
  title: "CasaVPN is down",
  body: "vpn.example.com:443 is DOWN",
};
const dev = (token: string, environment: Device["environment"] = "production"): Device => ({ token, environment, name: "x", addedAt: "2026-10-22T00:00:00.000Z" });

async function envWithKey() {
  const key = await makeKey();
  return { key, env: { APNS_KEY_P8: key.pem, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234", APNS_TOPIC: "com.example.casavpn" } };
}

test("signJwt makes an ES256 JWT whose signature verifies with the public key", async () => {
  const { key, env } = await envWithKey();
  const jwt = await signJwt(env.APNS_KEY_P8, env.APNS_KEY_ID, env.APNS_TEAM_ID, 1790000000);
  const [h, c, s] = jwt.split(".");
  assert.deepEqual(decodeJson(h!), { alg: "ES256", kid: "KEYID12345" });
  assert.deepEqual(decodeJson(c!), { iss: "TEAMID1234", iat: 1790000000 });
  const sig = b64urlToBytes(s!);
  assert.equal(sig.length, 64, "raw r||s, not DER");
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key.publicKey, sig, new TextEncoder().encode(`${h}.${c}`));
  assert.equal(ok, true);
  const tampered = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key.publicKey, sig, new TextEncoder().encode(`${h}.${c}x`));
  assert.equal(tampered, false);
  assert.doesNotMatch(jwt, /[+/=]/);
});

test("the JWT is cached for 50 minutes", async () => {
  resetJwtCache();
  const { env } = await envWithKey();
  const first = await getJwt(env, NOW);
  assert.equal(await getJwt(env, NOW + 49 * 60_000), first);
  const later = await getJwt(env, NOW + 51 * 60_000);
  assert.notEqual(later, first);
  assert.equal(decodeJson(later.split(".")[1]!).iat, Math.floor((NOW + 51 * 60_000) / 1000));
  // A different key id is a different token.
  assert.notEqual(await getJwt({ ...env, APNS_KEY_ID: "OTHERKEY99" }, NOW + 51 * 60_000), later);
});

test("payload matches the contract", () => {
  assert.deepEqual(JSON.parse(payloadFor(alert)), {
    aps: {
      alert: { title: "CasaVPN is down", body: "vpn.example.com:443 is DOWN" },
      sound: "default",
      "thread-id": "vpn",
      "interruption-level": "time-sensitive",
    },
    alertId: "00a1b2c3d4e5-abcdef",
    kind: "vpn.down",
  });
  const warn = JSON.parse(payloadFor({ ...alert, kind: "test", severity: "warning" }));
  assert.equal(warn.aps["thread-id"], "test");
  assert.equal(warn.aps["interruption-level"], "active");
});

test("sendPush: hosts, headers and priority", async () => {
  resetJwtCache();
  const { env } = await envWithKey();
  const f = fakeFetch();
  const r = await sendPush(env, [dev(TOKEN_A), dev(TOKEN_B, "sandbox")], alert, { fetch: f.fn, now: () => NOW });
  assert.equal(r.pushed, 2);
  assert.deepEqual(r.invalid, []);
  const prod = f.calls.find((c) => c.url.includes(TOKEN_A))!;
  const sand = f.calls.find((c) => c.url.includes(TOKEN_B))!;
  assert.equal(prod.url, `https://api.push.apple.com/3/device/${TOKEN_A}`);
  assert.equal(sand.url, `https://api.sandbox.push.apple.com/3/device/${TOKEN_B}`);
  const h = prod.init.headers as Record<string, string>;
  assert.match(h.authorization!, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.equal(h["apns-topic"], "com.example.casavpn");
  assert.equal(h["apns-push-type"], "alert");
  assert.equal(h["apns-priority"], "10");
  assert.equal(prod.init.method, "POST");
  assert.equal(prod.init.body, payloadFor(alert));
  // One signature serves both devices.
  assert.equal((sand.init.headers as Record<string, string>).authorization, h.authorization);

  const info = fakeFetch();
  await sendPush(env, [dev(TOKEN_A)], { ...alert, severity: "info" }, { fetch: info.fn, now: () => NOW });
  assert.equal((info.calls[0]!.init.headers as Record<string, string>)["apns-priority"], "5");
  const warning = fakeFetch();
  await sendPush(env, [dev(TOKEN_A)], { ...alert, severity: "warning" }, { fetch: warning.fn, now: () => NOW });
  assert.equal((warning.calls[0]!.init.headers as Record<string, string>)["apns-priority"], "10");
});

test("sendPush: 410 and 400 BadDeviceToken mark a token dead; other failures do not", async () => {
  resetJwtCache();
  const { env } = await envWithKey();
  const t = (c: string) => c.repeat(64);
  const answers: Record<string, () => Response> = {
    [t("1")]: () => new Response("", { status: 410 }),
    [t("2")]: () => Response.json({ reason: "BadDeviceToken" }, { status: 400 }),
    [t("3")]: () => Response.json({ reason: "PayloadEmpty" }, { status: 400 }),
    [t("4")]: () => Response.json({ reason: "TooManyRequests" }, { status: 429 }),
    [t("5")]: () => new Response("<html>", { status: 500 }),
    [t("6")]: () => new Response("", { status: 200 }),
  };
  const f = fakeFetch((c) => answers[c.url.split("/").pop()!]!());
  const logs: string[] = [];
  const log = console.log;
  console.log = (m: string) => logs.push(m);
  try {
    const r = await sendPush(env, Object.keys(answers).map((k) => dev(k)), alert, { fetch: f.fn, now: () => NOW });
    assert.equal(r.pushed, 1);
    assert.deepEqual(r.invalid.sort(), [t("1"), t("2")]);
  } finally {
    console.log = log;
  }
  assert.equal(logs.length, 3, "the three other failures are logged");
});

test("sendPush: a network error is logged, never thrown", async () => {
  resetJwtCache();
  const { env } = await envWithKey();
  const f = fakeFetch(() => {
    throw new Error("network down");
  });
  const log = console.log;
  console.log = () => {};
  try {
    const r = await sendPush(env, [dev(TOKEN_A)], alert, { fetch: f.fn, now: () => NOW });
    assert.deepEqual(r, { pushed: 0, invalid: [] });
  } finally {
    console.log = log;
  }
});

test("sendPush: a 403 drops the cached JWT", async () => {
  resetJwtCache();
  const { env } = await envWithKey();
  const first = await getJwt(env, NOW);
  const f = fakeFetch(() => Response.json({ reason: "ExpiredProviderToken" }, { status: 403 }));
  const log = console.log;
  console.log = () => {};
  try {
    await sendPush(env, [dev(TOKEN_A)], alert, { fetch: f.fn, now: () => NOW + 1000 });
  } finally {
    console.log = log;
  }
  assert.notEqual(await getJwt(env, NOW + 2000), first);
});

test("sendPush: no secrets or no devices means no requests", async () => {
  resetJwtCache();
  const { env } = await envWithKey();
  const f = fakeFetch();
  const deps = { fetch: f.fn, now: () => NOW };
  assert.deepEqual(await sendPush({}, [dev(TOKEN_A)], alert, deps), { pushed: 0, invalid: [] });
  assert.deepEqual(await sendPush({ ...env, APNS_TOPIC: "" }, [dev(TOKEN_A)], alert, deps), { pushed: 0, invalid: [] });
  assert.deepEqual(await sendPush(env, [], alert, deps), { pushed: 0, invalid: [] });
  assert.equal(f.calls.length, 0);
});

test("sendPush: an unusable key logs and pushes nothing", async () => {
  resetJwtCache();
  const f = fakeFetch();
  const log = console.log;
  console.log = () => {};
  try {
    const env = { APNS_KEY_P8: pem("AAAA"), APNS_KEY_ID: "K", APNS_TEAM_ID: "T", APNS_TOPIC: "t" };
    assert.deepEqual(await sendPush(env, [dev(TOKEN_A)], alert, { fetch: f.fn, now: () => NOW }), { pushed: 0, invalid: [] });
  } finally {
    console.log = log;
  }
  assert.equal(f.calls.length, 0);
});
