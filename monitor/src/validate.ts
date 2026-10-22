// Strict request-body validation for the relay API. Unknown fields are refused,
// so a typo in a host script fails loudly instead of being ignored.

import type { Event, Severity } from "./store.ts";

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

/** The largest request body the relay reads. */
export const MAX_BODY_BYTES = 4096;

const KIND_RE = /^[a-z._]{1,32}$/;
/** APNs tokens are 32 bytes today; leave room for longer ones. */
export const DEVICE_TOKEN_RE = /^[0-9a-fA-F]{32,200}$/;
const SEVERITIES: readonly string[] = ["critical", "warning", "info"];
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;

function asObject(v: unknown, allowed: string[]): Record<string, unknown> | string {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return "body must be a JSON object";
  for (const k of Object.keys(v)) if (!allowed.includes(k)) return `unknown field: ${k}`;
  return v as Record<string, unknown>;
}

function text(o: Record<string, unknown>, field: string, min: number, max: number): string | { error: string } {
  const v = o[field];
  if (typeof v !== "string") return { error: `${field} must be a string` };
  if (v.length < min || v.length > max) return { error: `${field} must be ${min}-${max} characters` };
  if (CONTROL_RE.test(v)) return { error: `${field} has control characters` };
  return v;
}

export function parseDevice(v: unknown): Parsed<{ token: string; environment: "sandbox" | "production"; name: string }> {
  const o = asObject(v, ["token", "environment", "name"]);
  if (typeof o === "string") return { ok: false, error: o };
  if (typeof o.token !== "string" || !DEVICE_TOKEN_RE.test(o.token)) return { ok: false, error: "token must be hex" };
  if (o.environment !== "sandbox" && o.environment !== "production") {
    return { ok: false, error: "environment must be sandbox or production" };
  }
  const name = text(o, "name", 1, 40);
  if (typeof name !== "string") return { ok: false, error: name.error };
  return { ok: true, value: { token: o.token.toLowerCase(), environment: o.environment, name } };
}

export function parseEvent(v: unknown): Parsed<Event> {
  const o = asObject(v, ["kind", "severity", "title", "body", "dedupe"]);
  if (typeof o === "string") return { ok: false, error: o };
  if (typeof o.kind !== "string" || !KIND_RE.test(o.kind)) return { ok: false, error: "kind must match [a-z._]{1,32}" };
  if (typeof o.severity !== "string" || !SEVERITIES.includes(o.severity)) {
    return { ok: false, error: "severity must be critical, warning or info" };
  }
  const title = text(o, "title", 1, 80);
  if (typeof title !== "string") return { ok: false, error: title.error };
  const body = text(o, "body", 0, 400);
  if (typeof body !== "string") return { ok: false, error: body.error };
  const event: Event = { kind: o.kind, severity: o.severity as Severity, title, body };
  if (o.dedupe !== undefined) {
    const dedupe = text(o, "dedupe", 1, 64);
    if (typeof dedupe !== "string") return { ok: false, error: dedupe.error };
    event.dedupe = dedupe;
  }
  return { ok: true, value: event };
}
