import { assertEquals, assertThrows } from "@std/assert";
import { Clock } from "./clock.ts";

Deno.test("Clock starts paused at t=0", () => {
  const c = new Clock(5000);
  assertEquals(c.t, 0);
  assertEquals(c.state, "paused");
  assertEquals(c.speed, 1);
});

Deno.test("Clock.tick is a no-op while paused", () => {
  const c = new Clock(5000);
  assertEquals(c.tick(100), 0);
  assertEquals(c.t, 0);
});

Deno.test("Clock advances by wallDt * speed when playing", () => {
  const c = new Clock(5000);
  c.play();
  assertEquals(c.tick(100), 100);
  assertEquals(c.t, 100);
  c.setSpeed(2);
  assertEquals(c.tick(100), 200);
  assertEquals(c.t, 300);
});

Deno.test("Clock pins at duration and pauses", () => {
  const c = new Clock(1000);
  c.play();
  const dt = c.tick(2000);
  assertEquals(c.t, 1000);
  assertEquals(dt, 1000);
  assertEquals(c.state, "paused");
});

Deno.test("Clock.play() at end stays at end (restart is engine-level)", () => {
  const c = new Clock(1000);
  c.play();
  c.tick(2000);
  assertEquals(c.t, 1000);
  // Calling play() at the end leaves t alone; the engine's intent
  // handler is responsible for restarting the world before playing
  // (without that, rewinding the clock without rewinding the world
  // would leave the simulation inconsistent).
  c.play();
  assertEquals(c.t, 1000);
  assertEquals(c.state, "playing");
});

Deno.test("Clock.restart() resets state and time", () => {
  const c = new Clock(1000);
  c.play();
  c.tick(500);
  c.restart();
  assertEquals(c.t, 0);
  assertEquals(c.state, "paused");
});

Deno.test("Clock.setSpeed rejects non-positive values", () => {
  const c = new Clock(1000);
  assertThrows(() => c.setSpeed(0), RangeError);
  assertThrows(() => c.setSpeed(-1), RangeError);
  assertThrows(() => c.setSpeed(NaN), RangeError);
});

Deno.test("Clock.tick rejects negative wallDt", () => {
  const c = new Clock(1000);
  c.play();
  assertThrows(() => c.tick(-1), RangeError);
});

Deno.test("Clock.toggle flips state", () => {
  const c = new Clock(1000);
  c.toggle();
  assertEquals(c.state, "playing");
  c.toggle();
  assertEquals(c.state, "paused");
});

Deno.test("Clock determinism: same state transitions => same t", () => {
  const a = new Clock(5000);
  const b = new Clock(5000);
  for (
    const [op, dt] of [
      ["play", 0],
      ["tick", 100],
      ["setSpeed", 2],
      ["tick", 100],
      ["pause", 0],
      ["tick", 500],
      ["play", 0],
      ["tick", 50],
    ] as Array<["play" | "pause" | "tick" | "setSpeed", number]>
  ) {
    if (op === "play") a.play(), b.play();
    else if (op === "pause") a.pause(), b.pause();
    else if (op === "tick") a.tick(dt), b.tick(dt);
    else if (op === "setSpeed") a.setSpeed(dt), b.setSpeed(dt);
  }
  assertEquals(a.t, b.t);
});
