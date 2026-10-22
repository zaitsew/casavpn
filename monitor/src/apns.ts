// Apple Push Notification service sender. Plain fetch() from a Worker reaches
// APNs over HTTP/2; the only credential is an ES256 JWT signed with the .p8 key.

import type { Alert, Device } from "./store.ts";

export interface ApnsEnv {
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
}

export interface ApnsDeps {
  fetch: typeof fetch;
  /** Epoch milliseconds. */
  now: () => number;
}

const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };
/** Apple accepts a token for an hour and refuses one refreshed more than every 20 minutes. */
const JWT_TTL_MS = 50 * 60 * 1000;
const PUSH_TIMEOUT_MS = 8000;

export function apnsConfigured(env: ApnsEnv): boolean {
  return !!(env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC);
}

function base64url(bytes: Uint8Array | string): string {
  const raw = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let s = "";
  for (const b of raw) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array {
  const b64 = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

/** A signed provider token: header.claims.signature, signature as raw r||s. */
export async function signJwt(p8: string, keyId: string, teamId: string, iatSeconds: number): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(p8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signingInput = `${base64url(JSON.stringify({ alg: "ES256", kid: keyId }))}.${base64url(JSON.stringify({ iss: teamId, iat: iatSeconds }))}`;
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput)));
  return `${signingInput}.${base64url(sig)}`;
}

// One token per isolate, reused for 50 minutes.
let cached: { id: string; jwt: string; at: number } | null = null;

export function resetJwtCache(): void {
  cached = null;
}

export async function getJwt(env: ApnsEnv, nowMs: number): Promise<string> {
  const id = `${env.APNS_TEAM_ID}|${env.APNS_KEY_ID}|${env.APNS_KEY_P8}`;
  if (cached && cached.id === id && nowMs - cached.at < JWT_TTL_MS) return cached.jwt;
  const jwt = await signJwt(env.APNS_KEY_P8!, env.APNS_KEY_ID!, env.APNS_TEAM_ID!, Math.floor(nowMs / 1000));
  cached = { id, jwt, at: nowMs };
  return jwt;
}

export function payloadFor(alert: Alert): string {
  return JSON.stringify({
    aps: {
      alert: { title: alert.title, body: alert.body },
      sound: "default",
      "thread-id": alert.kind.split(".")[0],
      "interruption-level": alert.severity === "critical" ? "time-sensitive" : "active",
    },
    alertId: alert.id,
    kind: alert.kind,
  });
}

export interface PushResult {
  /** Devices APNs accepted the push for. */
  pushed: number;
  /** Tokens APNs says are dead (410, or 400 BadDeviceToken). */
  invalid: string[];
}

/** Sends one alert to every device. Never throws; a failed push is logged and skipped. */
export async function sendPush(env: ApnsEnv, devices: Device[], alert: Alert, deps: ApnsDeps): Promise<PushResult> {
  const result: PushResult = { pushed: 0, invalid: [] };
  if (!apnsConfigured(env) || devices.length === 0) return result;

  let jwt: string;
  try {
    jwt = await getJwt(env, deps.now());
  } catch (e) {
    console.log(JSON.stringify({ apns: "jwt_failed", error: e instanceof Error ? e.message : String(e) }));
    return result;
  }
  const body = payloadFor(alert);
  const priority = alert.severity === "info" ? "5" : "10";

  await Promise.all(
    devices.map(async (d) => {
      try {
        const res = await deps.fetch(`${HOSTS[d.environment === "sandbox" ? "sandbox" : "production"]}/3/device/${d.token}`, {
          method: "POST",
          headers: {
            authorization: `bearer ${jwt}`,
            "apns-topic": env.APNS_TOPIC!,
            "apns-push-type": "alert",
            "apns-priority": priority,
            "content-type": "application/json",
          },
          body,
          signal: AbortSignal.timeout(PUSH_TIMEOUT_MS),
        });
        if (res.ok) {
          result.pushed++;
          return;
        }
        const reason = await res.json().then((j) => (j as { reason?: string }).reason, () => undefined);
        if (res.status === 410 || (res.status === 400 && reason === "BadDeviceToken")) {
          result.invalid.push(d.token);
          return;
        }
        // A rejected provider token must not be reused for the next 50 minutes.
        if (res.status === 403) cached = null;
        console.log(JSON.stringify({ apns: "rejected", status: res.status, reason: reason ?? null }));
      } catch (e) {
        console.log(JSON.stringify({ apns: "failed", error: e instanceof Error ? e.message : String(e) }));
      }
    }),
  );
  return result;
}
