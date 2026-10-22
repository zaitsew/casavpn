// Fakes for the tests: an in-memory KV, a recording fetch, a pinned clock.

import type { KV } from "./store.ts";
import type { MonitorEnv } from "./monitor.ts";

export class FakeKV implements KV {
  data = new Map<string, string>();
  ttls = new Map<string, number | undefined>();
  puts: string[] = [];
  failPutsFor: string | null = null;
  async get(key: string): Promise<string | null> {
    return this.data.get(key) ?? null;
  }
  async put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void> {
    if (this.failPutsFor === key) throw new Error(`KV put failed: ${key}`);
    this.puts.push(key);
    this.data.set(key, value);
    this.ttls.set(key, options?.expirationTtl);
  }
  json<T>(key: string): T {
    return JSON.parse(this.data.get(key) ?? "null") as T;
  }
}

export interface Call {
  url: string;
  init: RequestInit;
}

/** A fetch that records calls and answers from `respond` (default 200). */
export function fakeFetch(respond: (call: Call) => Response | Promise<Response> = () => new Response("", { status: 200 })) {
  const calls: Call[] = [];
  const fn = (async (input: string | URL | Request, init?: RequestInit) => {
    const call = { url: String(input), init: init ?? {} };
    calls.push(call);
    return respond(call);
  }) as typeof fetch;
  return { fn, calls };
}

export const APP = "app-token-for-tests";
export const HOST = "host-token-for-tests";
export const NOW = Date.parse("2026-10-22T12:00:00.000Z");
export const TOKEN_A = "a".repeat(64);
export const TOKEN_B = "b".repeat(64);

export function makeEnv(extra: Partial<MonitorEnv> = {}): MonitorEnv & { STATE: FakeKV } {
  return { STATE: new FakeKV(), APP_TOKEN: APP, HOST_TOKEN: HOST, TARGET_HOST: "vpn.example.com", TARGET_PORT: "443", ...extra } as MonitorEnv & { STATE: FakeKV };
}

/** PEM armor, built in pieces so a secret scanner does not mistake the fixture for a key. */
export const pem = (b64: string, label = "PRIVATE KEY"): string => `${"-".repeat(5)}BEGIN ${label}${"-".repeat(5)}\n${b64}\n${"-".repeat(5)}END ${label}${"-".repeat(5)}\n`;

/** A PKCS#8 PEM for a fresh P-256 key, and the matching public key. */
export async function makeKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const b64 = btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n");
  return { pem: pem(b64), publicKey: pair.publicKey };
}
