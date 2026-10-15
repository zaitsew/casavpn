import test from "node:test";
import assert from "node:assert/strict";
import { initialState, transition, type CheckResult } from "./transition.ts";

const T0 = "2026-10-15T10:00:00.000Z";
const T1 = "2026-10-15T10:05:00.000Z";
const T2 = "2026-10-15T10:10:00.000Z";
const ok = (ip = "198.51.100.10"): CheckResult => ({ ok: true, ip });
const fail = (error = "connect timeout", ip: string | null = "198.51.100.10"): CheckResult => ({ ok: false, ip, error });

test("healthy checks stay quiet and remember the IP", () => {
  const r = transition(initialState(T0), ok(), T1);
  assert.equal(r.alert, null);
  assert.equal(r.state.status, "up");
  assert.equal(r.state.ip, "198.51.100.10");
});

test("a single failure does not alert", () => {
  const r = transition(initialState(T0), fail(), T1);
  assert.equal(r.alert, null);
  assert.equal(r.state.status, "up");
  assert.equal(r.state.failures, 1);
});

test("two consecutive failures alert once: down", () => {
  const first = transition(initialState(T0), fail(), T1);
  const second = transition(first.state, fail(), T2);
  assert.equal(second.alert?.kind, "down");
  assert.match(second.alert?.message ?? "", /DOWN: connect timeout/);
  assert.equal(second.state.status, "down");
  assert.equal(second.state.since, T2);
});

test("a success between failures resets the count", () => {
  const a = transition(initialState(T0), fail(), T1);
  const b = transition(a.state, ok(), T2);
  const c = transition(b.state, fail(), T2);
  assert.equal(c.alert, null);
  assert.equal(c.state.failures, 1);
});

test("staying down does not repeat the alert", () => {
  let s = initialState(T0);
  const alerts: string[] = [];
  for (let i = 0; i < 6; i++) {
    const r = transition(s, fail(), T1);
    s = r.state;
    if (r.alert) alerts.push(r.alert.kind);
  }
  assert.deepEqual(alerts, ["down"]);
});

test("recovery alerts once, then goes quiet", () => {
  let s = transition(transition(initialState(T0), fail(), T1).state, fail(), T1).state;
  const rec = transition(s, ok("203.0.113.9"), T2);
  assert.equal(rec.alert?.kind, "recovered");
  assert.match(rec.alert?.message ?? "", /203\.0\.113\.9/);
  assert.match(rec.alert?.message ?? "", new RegExp(`Down since ${T1}`));
  s = rec.state;
  assert.equal(transition(s, ok("203.0.113.9"), T2).alert, null);
});

test("a DNS failure is reported as not resolving, and keeps the last known IP", () => {
  let s = transition(initialState(T0), ok(), T1).state;
  s = transition(s, fail("no address", null), T1).state;
  const r = transition(s, fail("no address", null), T2);
  assert.match(r.alert?.message ?? "", /does not resolve/);
  assert.equal(r.state.ip, "198.51.100.10");
});

test("the alert says where DNS points when the port is dead", () => {
  const s = transition(initialState(T0), fail("connect refused", "198.51.100.7"), T1).state;
  const r = transition(s, fail("connect refused", "198.51.100.7"), T2);
  assert.match(r.alert?.message ?? "", /resolves to 198\.51\.100\.7/);
});
