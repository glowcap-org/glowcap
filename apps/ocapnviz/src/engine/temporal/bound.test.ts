import { assertEquals } from "@std/assert";
import {
  type Bound,
  explicitBound,
  implicitBound,
  withExplicit,
  withImplicit,
  withValue,
} from "./bound.ts";

Deno.test("implicitBound seeds value, explicit=false", () => {
  assertEquals(implicitBound(7), { value: 7, explicit: false });
  assertEquals(implicitBound(), { value: 0, explicit: false });
});

Deno.test("explicitBound seeds value, explicit=true", () => {
  assertEquals(explicitBound(5), { value: 5, explicit: true });
});

Deno.test("withExplicit preserves stored value when flipping on", () => {
  const b: Bound = { value: 42, explicit: false };
  assertEquals(withExplicit(b), { value: 42, explicit: true });
});

Deno.test("withExplicit is a no-op when already explicit", () => {
  const b: Bound = { value: 3, explicit: true };
  assertEquals(withExplicit(b), b);
});

Deno.test("withImplicit preserves stored value when flipping off", () => {
  const b: Bound = { value: 9, explicit: true };
  assertEquals(withImplicit(b), { value: 9, explicit: false });
});

Deno.test("withImplicit is a no-op when already implicit", () => {
  const b: Bound = { value: 1, explicit: false };
  assertEquals(withImplicit(b), b);
});

Deno.test("withValue sets value and marks explicit", () => {
  const b: Bound = { value: 0, explicit: false };
  assertEquals(withValue(b, 12), { value: 12, explicit: true });
});

Deno.test("withValue overrides a previously-explicit value", () => {
  const b: Bound = { value: 5, explicit: true };
  assertEquals(withValue(b, 8), { value: 8, explicit: true });
});
